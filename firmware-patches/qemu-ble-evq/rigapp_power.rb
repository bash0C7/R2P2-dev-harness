# Device program of the power case (apply.sh copies it to storage/home/app.rb when EVQ_POWER=1).
# Walks hci_power_control through thirty-three steps and logs every BTSTACK_EVENT_STATE, every
# DISCONNECTION_COMPLETE and every heartbeat with the step it arrived in and the time. Log tokens:
#   [rigapp] power begin / power done
#   [rigapp] step <n> call <on|off|sleep> t=<ms>   written just before the call, so the
#                                                   NimBLE stub lines that follow belong to it
#   [rigapp] step <n> state <b2> t=<ms>   BTSTACK_EVENT_STATE (0x60), b2 = HCI state
#   [rigapp] step <n> disc <b3> t=<ms>    HCI_EVENT_DISCONNECTION_COMPLETE (0x05), b3 = handle low byte
#   [rigapp] step <n> meta t=<ms>         HCI_EVENT_LE_META (the link came up)
#   [rigapp] step <n> hb t=<ms>           a heartbeat
#   [rigapp] step <n> gap_connect <rc>
# Step 1 powers on through the library's own start (power-on, then its ensure powers off);
# the other steps call hci_power_control, for which the library offers no wrapper.
#  1 power-on (via start)            2 the power-off start ends with   3 power-off while off
#  4 power-on                        5 sleep                           6 power-on from sleep
#  7 power-on while on, one event in the ring (injected by the rig)
#  8 power-off with a connect attempt nobody answers
#  9 power-on, then a connect that a peer answers (the link comes up)
# 10 sleep with the link up          11 power-on from sleep, link up again
# 12 power-off with the link up
# Power transitions while a halt is still pending (the stubbed host answers terminate with
# BLE_HS_EALREADY once a link is terminating, and raises the disconnect late or never):
# 13 power-on, link up              14 power-off (disconnect armed to come 600 ms later)
# 15 power-on 100 ms later          16 power-off again; the disconnect of 14 arrives during it
# 17 power-on, link up              18 power-off  19 power-off again, halt still pending
# 20 power-on, link up              21 power-off  22 sleep during the pending power-off
# 23 power-on from sleep, link up   24 sleep      25 power-off during the pending sleep
# 26 power-on, link up              27 sleep      28 sleep again, halt still pending
# 29 power-on from sleep            30 power-on while on             31 power-off (heartbeat stops)
# A second BLE.new, powered off and connected afresh:
# 32 power-on                       33 gap_connect to a peer whose connect completes after the
#                                      cancel failed, then power-off at once: the link is
#                                      accepted after the halt completed
# Steps 8, 10 and 12 end with a terminated link or a cancelled attempt whose completion the
# stubbed host never delivers in time: the port's halting deadline has to produce it.
require 'ble'

class RigPower < BLE
  SILENT_PEER = "\xAA\x01\x02\x03\x04\x05"
  ANSWERING_PEER = "\xBB\x01\x02\x03\x04\x05"
  RACING_PEER = "\xCC\x01\x02\x03\x04\x05"

  def initialize
    super(:central)
  end

  def packet_callback(event_packet)
    t = event_packet.getbyte(0)
    now = Machine.board_millis
    puts "[rigapp] step #{@step} state #{event_packet.getbyte(2)} t=#{now}" if t == BTSTACK_EVENT_STATE
    puts "[rigapp] step #{@step} disc #{event_packet.getbyte(3)} t=#{now}" if t == HCI_EVENT_DISCONNECTION_COMPLETE
    puts "[rigapp] step #{@step} meta t=#{now}" if t == HCI_EVENT_LE_META
    super(event_packet)
  end

  def heartbeat_callback
  end

  def drain(step, ms = 400)
    @step = step
    deadline = Machine.board_millis + ms
    while Machine.board_millis < deadline
      event = @event_queue.pop(timeout_ms: 20)
      _event_popped if event
      if event.is_a?(String)
        packet_callback(event)
      elsif event
        puts "[rigapp] step #{step} hb t=#{Machine.board_millis}"
      end
    end
  end

  def call_power(step, what, mode)
    @step = step
    puts "[rigapp] step #{step} call #{what} t=#{Machine.board_millis}"
    hci_power_control(mode)
  end

  def call_connect(step, peer)
    puts "[rigapp] step #{step} gap_connect #{gap_connect(peer, 0)}"
  end

  def run
    @step = 1
    start(600)
    drain(2)
    call_power(3, "off", HCI_POWER_OFF)
    drain(3)
    call_power(4, "on", HCI_POWER_ON)
    drain(4, 1500)
    call_power(5, "sleep", HCI_POWER_SLEEP)
    drain(5, 1500)
    call_power(6, "on", HCI_POWER_ON)
    drain(6)
    call_power(7, "on", HCI_POWER_ON)
    drain(7)
    call_connect(8, SILENT_PEER)
    call_power(8, "off", HCI_POWER_OFF)
    drain(8, 1600)
    call_power(9, "on", HCI_POWER_ON)
    drain(9, 200)
    call_connect(9, ANSWERING_PEER)
    drain(9, 300)
    call_power(10, "sleep", HCI_POWER_SLEEP)
    drain(10, 1800)
    call_power(11, "on", HCI_POWER_ON)
    drain(11, 200)
    call_connect(11, ANSWERING_PEER)
    drain(11, 300)
    call_power(12, "off", HCI_POWER_OFF)
    drain(12, 1600)
    call_power(13, "on", HCI_POWER_ON)
    link_up(13)
    call_power(14, "off", HCI_POWER_OFF)
    drain(14, 100)
    call_power(15, "on", HCI_POWER_ON)
    drain(15, 100)
    call_power(16, "off", HCI_POWER_OFF)
    drain(16, 1600)
    call_power(17, "on", HCI_POWER_ON)
    link_up(17)
    call_power(18, "off", HCI_POWER_OFF)
    drain(18, 200)
    call_power(19, "off", HCI_POWER_OFF)
    drain(19, 1600)
    call_power(20, "on", HCI_POWER_ON)
    link_up(20)
    call_power(21, "off", HCI_POWER_OFF)
    drain(21, 200)
    call_power(22, "sleep", HCI_POWER_SLEEP)
    drain(22, 1600)
    call_power(23, "on", HCI_POWER_ON)
    link_up(23)
    call_power(24, "sleep", HCI_POWER_SLEEP)
    drain(24, 200)
    call_power(25, "off", HCI_POWER_OFF)
    drain(25, 1600)
    call_power(26, "on", HCI_POWER_ON)
    link_up(26)
    call_power(27, "sleep", HCI_POWER_SLEEP)
    drain(27, 200)
    call_power(28, "sleep", HCI_POWER_SLEEP)
    drain(28, 1600)
    call_power(29, "on", HCI_POWER_ON)
    drain(29, 1500)
    call_power(30, "on", HCI_POWER_ON)
    drain(30, 100)
    call_power(31, "off", HCI_POWER_OFF)
    drain(31, 1600)
  end

  def link_up(step)
    drain(step, 200)
    call_connect(step, ANSWERING_PEER)
    drain(step, 300)
  end

  def run_race
    call_power(32, "on", HCI_POWER_ON)
    drain(32, 200)
    call_connect(33, RACING_PEER)
    call_power(33, "off", HCI_POWER_OFF)
    drain(33, 1000)
  end
end

puts "[rigapp] power begin"
RigPower.new.run
RigPower.new.run_race
puts "[rigapp] power done"
