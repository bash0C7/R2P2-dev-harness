# firmware: picoruby-gpio の C の所 (src/mruby/gpio.c) と、FPGA の port (ports/rp2040/gpio.c の形を板のモデルの mmio で、D102)。
# mrblib (picoruby-gpio/mrblib/gpio.rb) はそのまま像に入る (tools/fpga/v2/build.rb)。板のモデルは tools/fpga/v2/board.rb
class GPIO
  # C: picoruby-gpio/src/mruby/gpio.c mrb__init
  def _init(pin)
    __fpga_gpio_init(__fpga_gpio_pin_num(pin))
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_set_function_at
  def self.set_function_at(pin, alt_function)
    f = __fpga_int32(__fpga_as_int(alt_function)) # mrb_get_args の "oi" (firmware-patches/gpio-pin-num-mrb-int.patch)
    __fpga_gpio_set_function(__fpga_gpio_pin_num(pin), f)
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_set_dir_at
  def self.set_dir_at(pin, flags)
    f = __fpga_int32(__fpga_as_int(flags))
    __fpga_gpio_set_dir(__fpga_gpio_pin_num(pin), f)
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_open_drain_at
  def self.open_drain_at(pin)
    __fpga_gpio_open_drain(__fpga_gpio_pin_num(pin))
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_pull_up_at
  def self.pull_up_at(pin)
    __fpga_gpio_pull_up(__fpga_gpio_pin_num(pin))
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_pull_down_at
  def self.pull_down_at(pin)
    __fpga_gpio_pull_down(__fpga_gpio_pin_num(pin))
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_high_at_p
  def self.high_at?(pin)
    __fpga_gpio_read(__fpga_as_int(pin)) == 0 ? false : true
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_low_at_p
  def self.low_at?(pin)
    __fpga_gpio_read(__fpga_as_int(pin)) == 0 ? true : false
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_read_at
  def self.read_at(pin)
    __fpga_gpio_read(__fpga_gpio_pin_num(pin))
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_s_write_at
  def self.write_at(pin, val)
    value = __fpga_int32(__fpga_as_int(val))
    pin_number = __fpga_gpio_pin_num(pin)
    if (value == 0 || value == 1) == false
      __fpga_raise(ArgumentError, "Wrong value. 0 and 1 are only valid")
    end
    __fpga_gpio_write(pin_number, value)
    0
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_high_p
  def high?
    __fpga_gpio_read(__fpga_gpio_ivpinnum(self)) == 0 ? false : true
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_low_p
  def low?
    __fpga_gpio_read(__fpga_gpio_ivpinnum(self)) == 0 ? true : false
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_read
  def read
    __fpga_gpio_read(__fpga_gpio_ivpinnum(self))
  end

  # C: picoruby-gpio/src/mruby/gpio.c mrb_write
  def write(val)
    value = __fpga_as_int(val) # mrb_get_args の "i" (mrb_int)
    if (value == 0 || value == 1) == false
      __fpga_raise(ArgumentError, "Wrong value. 0 and 1 are only valid")
    end
    __fpga_gpio_write(__fpga_gpio_ivpinnum(self), value)
    0
  end
end

class Object
  # GPIO の定数 (クラスは起動の像が作る、Image::CORE)
  # C: picoruby-gpio/src/mruby/gpio.c mrb_picoruby_gpio_gem_init
  def __fpga_init_gpio
    t = __fpga_ld32(__fpga_addr(GPIO) + 60) # L:C_IV
    __fpga_tbl_set(t, __fpga_addr(:IN), 1)
    __fpga_tbl_set(t, __fpga_addr(:OUT), 2)
    __fpga_tbl_set(t, __fpga_addr(:HIGH_Z), 4)
    __fpga_tbl_set(t, __fpga_addr(:PULL_UP), 8)
    __fpga_tbl_set(t, __fpga_addr(:PULL_DOWN), 16)
    __fpga_tbl_set(t, __fpga_addr(:OPEN_DRAIN), 32)
    __fpga_tbl_set(t, __fpga_addr(:ALT), 64)
  end

  # Integer は int に (mrb_integer を int の pin_number に)、String と Symbol は port の GPIO_pin_num_from_char (-1)、ほかは -1
  # C: picoruby-gpio/src/mruby/gpio.c pin_num
  def __fpga_gpio_pin_num(pin)
    pin_number = __fpga_tag(pin) == 3 ? __fpga_int32(pin) : __fpga_gpio_pin_num_from_char(pin) # L:TAG_INT
    __fpga_raisef(ArgumentError, "Wrong GPIO pin name: %v", [pin]) if pin_number < 0
    pin_number
  end

  # C: picoruby-gpio/src/mruby/gpio.c IVPINNUM
  def __fpga_gpio_ivpinnum(obj)
    __fpga_int(__fpga_iv_get(obj, __fpga_addr(:@pin)))
  end

  # --- port (FPGA の板のモデル。引数の pin は uint8_t)
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_pin_num_from_char (D102)
  def __fpga_gpio_pin_num_from_char(str)
    -1 # Not supported (rp2040 と posix の port と同じ)
  end

  # ピンの bit。32 以上のピンは無い (0、D101)
  # C: none (D101)
  def __fpga_gpio_bit(pin)
    p = __fpga_and(pin, 255) # uint8_t
    p < 32 ? __fpga_shl(1, p) : 0 # L:GPIO_PINS
  end

  # gpio_init: 入力にして latch を 0 に
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_init (D102)
  def __fpga_gpio_init(pin)
    clear = __fpga_xor(__fpga_gpio_bit(pin), 4294967295)
    __fpga_st32(67108868, __fpga_and(__fpga_ld32(67108868), clear)) # L:MMIO_GPIO_DIR
    __fpga_st32(67108864, __fpga_and(__fpga_ld32(67108864), clear)) # L:MMIO_GPIO_OUT
  end

  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_set_dir (D102)
  def __fpga_gpio_set_dir(pin, dir)
    bit = __fpga_gpio_bit(pin)
    d = __fpga_and(dir, 255) # uint8_t
    if d == 1 # IN
      __fpga_st32(67108868, __fpga_and(__fpga_ld32(67108868), __fpga_xor(bit, 4294967295))) # L:MMIO_GPIO_DIR
    elsif d == 2 # OUT
      __fpga_st32(67108868, __fpga_or(__fpga_ld32(67108868), bit)) # L:MMIO_GPIO_DIR
    end
    # HIGH_Z is not supported
  end

  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_open_drain (D102)
  def __fpga_gpio_open_drain(pin)
    # Not supported
  end

  # gpio_pull_up: pull up を立て、pull down を下ろす
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_pull_up (D102)
  def __fpga_gpio_pull_up(pin)
    bit = __fpga_gpio_bit(pin)
    __fpga_st32(67108876, __fpga_or(__fpga_ld32(67108876), bit)) # L:MMIO_GPIO_PULL_UP
    __fpga_st32(67108880, __fpga_and(__fpga_ld32(67108880), __fpga_xor(bit, 4294967295))) # L:MMIO_GPIO_PULL_DOWN
  end

  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_pull_down (D102)
  def __fpga_gpio_pull_down(pin)
    bit = __fpga_gpio_bit(pin)
    __fpga_st32(67108880, __fpga_or(__fpga_ld32(67108880), bit)) # L:MMIO_GPIO_PULL_DOWN
    __fpga_st32(67108876, __fpga_and(__fpga_ld32(67108876), __fpga_xor(bit, 4294967295))) # L:MMIO_GPIO_PULL_UP
  end

  # 32 以上のピンは 1 (D101)
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_read (D102)
  def __fpga_gpio_read(pin)
    p = __fpga_and(pin, 255) # uint8_t
    return 1 if p >= 32 # L:GPIO_PINS
    __fpga_and(__fpga_shr(__fpga_ld32(67108872), p), 1) # L:MMIO_GPIO_IN
  end

  # gpio_put(pin, val == 1)
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_write (D102)
  def __fpga_gpio_write(pin, val)
    bit = __fpga_gpio_bit(pin)
    out = __fpga_ld32(67108864) # L:MMIO_GPIO_OUT
    out = __fpga_and(val, 255) == 1 ? __fpga_or(out, bit) : __fpga_and(out, __fpga_xor(bit, 4294967295))
    __fpga_st32(67108864, out) # L:MMIO_GPIO_OUT
  end

  # 板のモデルに別の機能は無い (D101)
  # C: picoruby-gpio/ports/rp2040/gpio.c GPIO_set_function (D102)
  def __fpga_gpio_set_function(pin, function)
  end
end
