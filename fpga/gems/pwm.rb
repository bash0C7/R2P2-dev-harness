# FPGA 版の pwm gem。API は PicoRuby の picoruby-pwm (mrblib/pwm.rb と src/mruby/pwm.c) と同じ。
# 設定はデバイス (tools/fpga/devices.rb の PWM_*、0x140 から) に書く: 周波数は mHz、duty は 1/1000 % の整数。
class PWM
  def initialize(pin, frequency: 0, duty: 50)
    @pin = pin
    _init(@pin)
    @frequency = frequency.to_f
    @duty = duty.to_f
    frequency(@frequency)
  end

  def _init(pin)
    0
  end

  # 0 は止める (設定は書かない)
  def __push(freq)
    @frequency = freq
    __io_write(0x140, @pin)
    if freq > 0
      __io_write(0x142, (@duty * 1000).round)
      __io_write(0x141, (freq * 1000).round)
    else
      __io_write(0x141, 0)
    end
  end

  def frequency(freq)
    raise TypeError, "wrong argument type" unless freq.is_a?(Float) || freq.is_a?(Integer)
    __push(freq.to_f)
    freq.to_f
  end

  def period_us(period_us)
    raise ArgumentError, "period must be positive" if period_us <= 0
    freq = 1000000.0 / period_us
    __push(freq)
    freq
  end

  # duty は 0..100 に丸め、丸めた値を返す
  def __set_duty(duty)
    duty = 0.0 if duty < 0.0
    duty = 100.0 if duty > 100.0
    @duty = duty
    if @frequency > 0
      __io_write(0x140, @pin)
      __io_write(0x142, (duty * 1000).round)
    end
    duty
  end

  def duty(duty)
    raise TypeError, "wrong argument type" unless duty.is_a?(Float) || duty.is_a?(Integer)
    __set_duty(duty.to_f)
  end

  def pulse_width_us(pulse_width)
    __set_duty(pulse_width.to_f / 10000.0 * @frequency)
  end
end
