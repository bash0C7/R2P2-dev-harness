# FPGA 版の gpio gem。API は PicoRuby の picoruby-gpio (mrblib/gpio.rb と sig/gpio.rbs) と同じ。
# C の port の関数 (read_at、write_at、set_dir_at ...) を、デバイスのレジスタ (tools/fpga/devices.rb、
# 0x100 から) を読み書きする Ruby で書いた。ピンは 0..31 の Integer。
class GPIO
  IN         = 1
  OUT        = 2
  HIGH_Z     = 4
  PULL_UP    = 8
  PULL_DOWN  = 16
  OPEN_DRAIN = 32
  ALT        = 64
  # irq gem の定数 (PicoRuby では irq が足す)
  LEVEL_LOW  = 1
  LEVEL_HIGH = 2
  EDGE_FALL  = 4
  EDGE_RISE  = 8

  def initialize(pin, flags, alt_function = 0)
    @initializing = true
    @pin = GPIO.__pin(pin)
    setmode(flags, alt_function)
    raise ArgumentError, "You must specify one of IN, OUT, HIGH_Z, and ALT" unless @dir || @alt_function
    @initializing = false
  end

  attr_reader :pin

  def setmode(flags, alt_function = 0)
    set_dir(flags)
    set_pull(flags)
    open_drain(flags)
    set_function(flags, alt_function)
  end

  def set_function(flags, alt_function)
    @alt_function = if alt_function > 0 && (flags & ALT) == ALT
                      GPIO.set_function_at(@pin, alt_function)
                      alt_function
                    end
    0
  end

  def set_dir(flags)
    dir = flags & (IN | OUT | HIGH_Z)
    return 0 if dir == 0 && !@initializing
    mode_dir = (flags & IN) + ((flags & OUT) >> 1) + ((flags & HIGH_Z) >> 2)
    raise ArgumentError, "IN, OUT and HIGH_Z are exclusive" if mode_dir > 1
    @dir = mode_dir == 0 ? nil : dir
    GPIO.set_dir_at(@pin, dir) if @dir
    0
  end

  def set_pull(flags)
    pull = flags & (PULL_UP | PULL_DOWN)
    return 0 if pull == 0 && !@initializing
    raise ArgumentError, "PULL_UP and PULL_DOWN are exclusive" if pull == (PULL_UP | PULL_DOWN)
    @pull = pull == 0 ? nil : pull
    GPIO.pull_up_at(@pin) if pull == PULL_UP
    GPIO.pull_down_at(@pin) if pull == PULL_DOWN
    0
  end

  def open_drain(flags)
    @open_drain = (flags & OPEN_DRAIN) > 0
    GPIO.open_drain_at(@pin) if @open_drain
    0
  end

  def read
    GPIO.read_at(@pin)
  end

  def write(value)
    GPIO.write_at(@pin, value)
  end

  def high?
    GPIO.high_at?(@pin)
  end

  def low?
    GPIO.low_at?(@pin)
  end

  def self.__pin(pin)
    raise ArgumentError, "GPIO pin must be an Integer 0..31 on the FPGA" unless pin.is_a?(Integer) && pin >= 0 && pin < 32
    pin
  end

  # レジスタ addr の pin の bit を on / off にする
  def self.__set(addr, pin, on)
    bit = 1 << __pin(pin)
    v = __io_read(addr)
    __io_write(addr, on ? (v | bit) : (v & ~bit))
    0
  end

  def self.read_at(pin)
    (__io_read(0x105) >> __pin(pin)) & 1
  end

  def self.high_at?(pin)
    read_at(pin) == 1
  end

  def self.low_at?(pin)
    read_at(pin) == 0
  end

  def self.write_at(pin, value)
    __set(0x101, pin, value != 0 && value != false && !value.nil?)
  end

  def self.set_dir_at(pin, dir)
    __set(0x100, pin, dir == OUT)
  end

  def self.pull_up_at(pin)
    __set(0x103, pin, false)
    __set(0x102, pin, true)
  end

  def self.pull_down_at(pin)
    __set(0x102, pin, false)
    __set(0x103, pin, true)
  end

  def self.open_drain_at(pin)
    __set(0x104, pin, true)
  end

  # 別の機能 (UART、PWM ...) にピンを渡す。FPGA のピンは機能ごとに決まっているので何もしない
  def self.set_function_at(pin, alt_function)
    __pin(pin)
    0
  end
end
