# Device program of the power case (apply.sh copies it to storage/home/app.rb when EVQ_POWER=1).
# Walks hci_power_control through seven steps and logs every BTSTACK_EVENT_STATE
# (and the injected DISCONNECTION_COMPLETE) with the step it arrived in. Log tokens:
#   [rigapp] power begin / power done
#   [rigapp] step <n> state <b2>   BTSTACK_EVENT_STATE (0x60), b2 = HCI state
#   [rigapp] step <n> disc <b3>    HCI_EVENT_DISCONNECTION_COMPLETE (0x05), b3 = handle low byte
# Step 1 powers on through the library's own start (power-on, then its ensure powers off);
# the other steps call hci_power_control, for which the library offers no wrapper.
require 'ble'

class RigPower < BLE
  def initialize
    super(:central)
  end

  def packet_callback(event_packet)
    t = event_packet.getbyte(0)
    puts "[rigapp] step #{@step} state #{event_packet.getbyte(2)}" if t == BTSTACK_EVENT_STATE
    puts "[rigapp] step #{@step} disc #{event_packet.getbyte(3)}" if t == HCI_EVENT_DISCONNECTION_COMPLETE
    super(event_packet)
  end

  def heartbeat_callback
  end

  def drain(step)
    @step = step
    deadline = Machine.board_millis + 400
    while Machine.board_millis < deadline
      event = @event_queue.pop(timeout_ms: 20)
      _event_popped if event
      packet_callback(event) if event.is_a?(String)
    end
  end

  def run
    @step = 1
    start(600)
    drain(2)
    hci_power_control(HCI_POWER_OFF)
    drain(3)
    hci_power_control(HCI_POWER_ON)
    drain(4)
    hci_power_control(HCI_POWER_SLEEP)
    drain(5)
    hci_power_control(HCI_POWER_ON)
    drain(6)
    hci_power_control(HCI_POWER_ON)
    drain(7)
  end
end

puts "[rigapp] power begin"
RigPower.new.run
puts "[rigapp] power done"
