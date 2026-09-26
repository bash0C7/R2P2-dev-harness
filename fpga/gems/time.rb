# FPGA 版の Time。API は PicoRuby の picoruby-time (src/mruby/time.c) のうち、時刻を読んで比べる所。
# Time.now は仮想の時計 (tools/fpga/devices.rb の TIME_US、電源を入れてからの µs) を 1970-01-01 00:00:00 UTC からの時刻とみなす。
# 値は秒と µs に分けて持つ (Integer は 32bit なので)。時差は 0
class Time
  include Comparable

  def self.now
    lo = __io_read(0x110)
    hi = __io_read(0x111)
    total = hi * 4294967296.0 + (lo < 0 ? lo + 4294967296.0 : lo)
    sec = (total / 1000000).floor
    new_at(sec, (total - sec * 1000000.0).to_i)
  end

  def self.at(t)
    return new_at(t, 0) if t.is_a?(Integer)
    sec = t.floor
    new_at(sec, ((t - sec) * 1000000).to_i)
  end

  def self.new_at(sec, usec)
    new(:__at, sec, usec)
  end

  # Time.new (引数なし) は now。年月日から作る形 (Time.local と同じ) はまだ無い
  def initialize(*args)
    if args.empty?
      t = Time.now
      @sec = t.to_i
      @usec = t.usec
    elsif args[0] == :__at
      @sec = args[1]
      @usec = args[2]
    else
      raise NotImplementedError, "Time.new with a date is not supported on the FPGA core"
    end
  end

  def to_i
    @sec
  end

  def usec
    @usec
  end

  def to_f
    @sec + @usec / 1000000.0
  end

  def <=>(other)
    return nil unless other.is_a?(Time)
    c = @sec <=> other.to_i
    c == 0 ? @usec <=> other.usec : c
  end

  def ==(other)
    other.is_a?(Time) && (self <=> other) == 0
  end

  # Time - Time は秒 (Float)、Time - 数は Time
  def -(other)
    return (@sec - other.to_i) + (@usec - other.usec) / 1000000.0 if other.is_a?(Time)
    self + (-other)
  end

  def +(other)
    return Time.new_at(@sec + other, @usec) if other.is_a?(Integer)
    us = @usec + ((other - other.floor) * 1000000).to_i
    Time.new_at(@sec + other.floor + us / 1000000, us % 1000000)
  end

  # 1970-01-01 からの日数から [年, 月, 日] (Howard Hinnant の civil_from_days)
  def __time_civil
    z = @sec / 86400 + 719468
    era = z / 146097
    doe = z - era * 146097
    yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    mp = (5 * doy + 2) / 153
    d = doy - (153 * mp + 2) / 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y = yoe + era * 400
    y += 1 if m <= 2
    [y, m, d]
  end

  def year
    __time_civil[0]
  end

  def mon
    __time_civil[1]
  end

  def mday
    __time_civil[2]
  end

  def hour
    (@sec % 86400) / 3600
  end

  def min
    (@sec % 3600) / 60
  end

  def sec
    @sec % 60
  end

  def wday
    (@sec / 86400 + 4) % 7
  end

  def to_s
    y, m, d = __time_civil
    format("%04d-%02d-%02d %02d:%02d:%02d +0000", y, m, d, hour, min, sec)
  end

  def inspect
    y, m, d = __time_civil
    format("%04d-%02d-%02d %02d:%02d:%02d.%06d +0000", y, m, d, hour, min, sec, @usec)
  end
end
