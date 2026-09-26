# FPGA 版の watchdog gem。API は PicoRuby の picoruby-watchdog (sig/watchdog.rbs、ports/rp2040) と同じ。
# デバイス (tools/fpga/devices.rb の WDT_*、0x170 から) が仮想の時計で期限を見て、過ぎたらコアごと再起動する。
class Watchdog
  RP2040_MAX_ENABLE_MS = 8388

  def self.enable(delay_ms, pause_on_debug = true)
    __io_write(0x170, delay_ms)
    0
  end

  def self.disable
    __io_write(0x171, 0)
    0
  end

  def self.reboot(delay_ms)
    puts "\nRebooting in #{delay_ms} ms"
    __io_write(0x175, delay_ms)
    nil
  end

  # 時計は仮想の時計 (1µs) なので何もしない
  def self.start_tick(cycle)
    0
  end

  def self.update
    __io_write(0x172, 0)
    0
  end

  def self.feed
    update
  end

  def self.caused_reboot?
    __io_read(0x173) == 1
  end

  def self.enable_caused_reboot?
    __io_read(0x173) == 1
  end

  # 期限までの µs
  def self.get_count
    __io_read(0x174)
  end
end
