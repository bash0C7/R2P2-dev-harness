# Device program of the limits case (apply.sh copies it to storage/home/app.rb when EVQ_LIMITS=1).
# Small on purpose: the on-device compile of the full rigapp.rb is at the mruby heap ceiling.
# Log tokens, one per packet seen (the verdict greps them):
#   [rigapp] state <b2>   BTSTACK_EVENT_STATE (0x60), b2 = HCI state
#   [rigapp] disc <b3>    HCI_EVENT_DISCONNECTION_COMPLETE (0x05), b3 = handle low byte
#   [rigapp] cansend      ATT_EVENT_CAN_SEND_NOW (0xB7)
#   [rigapp] mark <b2>    rig marker (0xFE)
require 'ble'

class RigObserver < BLE
  def initialize
    super(:central)
  end

  def start(timeout_ms = nil, stop_state = :no_stop)
    @event_queue.clear
    _event_queue_cleared
    hci_power_control(HCI_POWER_ON)
    while true
      event = @event_queue.pop(timeout_ms: 20)
      _event_popped if event
      if event.is_a?(String)
        packet_callback(event)
      elsif event
        heartbeat_callback
      end
    end
  ensure
    hci_power_control(HCI_POWER_OFF)
  end

  def advertising_report_callback(r)
    name = r.reports[:complete_local_name].to_s
    return unless name[0, 4] == "RIG-"
    puts "[rigapp] recv seq=#{name[4, 3].to_i} tin=#{name[8, 8].to_i} t=#{Machine.board_millis}"
  end

  def packet_callback(event_packet)
    t = event_packet.getbyte(0)
    if t == GATT_EVENT_NOTIFICATION
      puts "[rigapp] notif len=#{gatt_event_value(event_packet).bytesize} raw=#{event_packet.bytesize}"
    end
    puts "[rigapp] disc #{event_packet.getbyte(3)}" if t == HCI_EVENT_DISCONNECTION_COMPLETE
    puts "[rigapp] cansend" if t == 0xB7
    puts "[rigapp] state #{event_packet.getbyte(2)}" if t == BTSTACK_EVENT_STATE
    puts "[rigapp] mark #{event_packet.getbyte(2)}" if t == 0xFE
    super(event_packet)
  end

  def heartbeat_callback
  end
end

RigObserver.new.scan(stop_state: :no_stop)
