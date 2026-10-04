# Ruby side of the qemu-ble-evq rig: an autostarting central that logs
# every injected advertising report the moment it reaches Ruby.
# Copied to R2P2-ESP32/storage/home/app.rb by apply.sh; r2p2.rb
# autostarts it at boot (source, so the same file serves both VMs).
# Keeps to APIs both VMs (mruby / mruby/c) implement.
require 'ble'

class RigObserver < BLE
  WRITE_HANDLE = 0x42
  FLOOD_HANDLE = 0x43
  WLAT_HANDLE = 0x44

  def start(timeout_ms = nil, stop_state = :no_stop)
    started_at = Machine.board_millis
    @event_queue.clear
    _event_queue_cleared
    hci_power_control(HCI_POWER_ON)
    while true
      break if timeout_ms && timeout_ms <= Machine.board_millis - started_at
      break if @state == stop_state
      event = @event_queue.pop(timeout_ms: 20)
      _event_popped if event
      if event.is_a?(String)
        packet_callback(event)
      elsif event
        heartbeat_callback
      end
      drain_writes
      drain_wlat
      drain_flood
    end
    Machine.board_millis - started_at
  ensure
    hci_power_control(HCI_POWER_OFF)
  end

  def drain_wlat
    while (v = pop_write_value(WLAT_HANDLE))
      puts "[rigapp] wlat tin=#{v.to_i} t=#{Machine.board_millis}"
    end
  end

  def initialize
    super(:central)
    @flood_received = 0
    @flood_bytes = 0
    mem_report("init")
  end

  def mem_report(tag)
    m = PicoRubyVM.memory_statistics
    puts "[rigapp] mem #{tag} total=#{m[:total]} used=#{m[:used]} free=#{m[:free]} frag=#{m[:frag]}"
  end

  def advertising_report_callback(r)
    drain_writes
    name = r.reports[:complete_local_name].to_s
    return unless name[0, 4] == "RIG-"
    seq = name[4, 3].to_i
    tin = name[8, 8].to_i
    puts "[rigapp] recv seq=#{seq} tin=#{tin} t=#{Machine.board_millis}"
  end

  def heartbeat_callback
    mem_report("hb total_received=#{@flood_received}") if @flood_received > 0
  end

  def drain_writes
    while (v = pop_write_value(WRITE_HANDLE))
      puts "[rigapp] write h=0x42 v=#{v.inspect}"
    end
  end

  def drain_flood
    while (v = pop_write_value(FLOOD_HANDLE))
      @flood_received += 1
      @flood_bytes += v.bytesize
      puts "[rigapp] flood received=#{@flood_received} bytes=#{@flood_bytes}" if @flood_received % 50 == 0
    end
  end
end

RigObserver.new.scan(stop_state: :no_stop)
