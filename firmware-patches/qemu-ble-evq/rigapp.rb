# Ruby side of the qemu-ble-evq rig: an autostarting central that logs
# every injected advertising report the moment it reaches Ruby.
# Copied to R2P2-ESP32/storage/home/app.rb by apply.sh; r2p2.rb
# autostarts it at boot (source, so the same file serves both VMs).
# Keeps to APIs both VMs (mruby / mruby/c) implement.
require 'ble'

class RigObserver < BLE
  WRITE_HANDLE = 0x42

  def initialize
    super(:central)
  end

  def advertising_report_callback(r)
    drain_writes
    name = r.reports[:complete_local_name].to_s
    return unless name[0, 4] == "RIG-"
    puts "[rigapp] recv seq=#{name[4, 8]} t=#{Machine.board_millis}"
  end

  def heartbeat_callback
    drain_writes
  end

  def drain_writes
    while (v = pop_write_value(WRITE_HANDLE))
      puts "[rigapp] write h=0x42 v=#{v.inspect}"
    end
  end
end

RigObserver.new.scan(stop_state: :no_stop)
