# FPGA 版の machine gem。API は PicoRuby の picoruby-machine (sig/machine.rbs) のうち FPGA で意味のあるもの。
# 時間は仮想の時計 (始めた命令の数 × 1µs + sleep した時間、tools/fpga/devices.rb の TIME_*) で、32bit で折り返す。
module Machine
  def self.uptime_us
    __io_read(0x110)
  end

  def self.board_millis
    __io_read(0x112)
  end

  def self.uptime_formatted
    ms = board_millis
    s = ms / 1000
    format("%d:%02d:%02d.%03d", s / 3600, (s / 60) % 60, s % 60, ms % 1000)
  end

  def self.delay_ms(ms)
    sleep_ms(ms)
    ms
  end

  def self.busy_wait_ms(ms)
    sleep_ms(ms)
    ms
  end

  # source: :timer は ms: だけ待つ。GPIO (pin を持つもの) は level: (GPIO::LEVEL_* / EDGE_*) になるまで 1ms ごとに見る
  def self.sleep(deep:, source:, ms: nil, level: nil)
    raise TypeError, "deep: must be true or false" unless deep == true || deep == false
    if source == :timer
      raise ArgumentError, "ms: must be an Integer" unless ms.is_a?(Integer)
      raise ArgumentError, "ms: out of range (1..4294967295)" if ms < 1
      sleep_ms(ms)
      return nil
    end
    raise ArgumentError, "source: must be :timer or respond to #pin" unless source.respond_to?(:pin)
    pin = source.pin
    last = GPIO.read_at(pin)
    while true
      now = GPIO.read_at(pin)
      return nil if (level == GPIO::LEVEL_LOW && now == 0) || (level == GPIO::LEVEL_HIGH && now == 1) ||
                    (level == GPIO::EDGE_FALL && last == 1 && now == 0) || (level == GPIO::EDGE_RISE && last == 0 && now == 1)
      last = now
      sleep_ms(1)
    end
  end

  def self.posix?
    false
  end

  def self.mcu_name
    "FPGA"
  end

  def self.wifi_available?
    false
  end
end
