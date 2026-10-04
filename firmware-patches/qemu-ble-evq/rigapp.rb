# Ruby side of the qemu-ble-evq rig: an autostarting central that logs
# every injected advertising report the moment it reaches Ruby.
# Copied to R2P2-ESP32/storage/home/app.rb by apply.sh; r2p2.rb
# autostarts it at boot (source, so the same file serves both VMs).
# Keeps to APIs both VMs (mruby / mruby/c) implement.
require 'ble'

class RigObserver < BLE
  WRITE_HANDLE = 0x42
  FLOOD_HANDLE = 0x43

  def initialize
    super(:central)
    @flood_received = 0
    @flood_bytes = 0
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
    drain_writes
    drain_flood
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
