# firmware: Kernel の C の所 (mruby の src/kernel.c、picoruby-machine の Kernel#puts / print は IO を通すが、FPGA はコンソールの
# primitive に直接書く) と BasicObject#method_missing (src/class.c、src/error.c)。
module Kernel
  # puts (mruby の mrblib には無く、picoruby-machine の kernel.rb が $stdout に渡す。改行で終わらなければ改行を足す)
  # C: none (D40)
  def puts(*args)
    n = __fpga_alen(args)
    if n == 0
      __fpga_putc(10)
      return nil
    end
    i = 0
    while i < n
      s = __fpga_aref(args, i).to_s
      __fpga_write_str(s)
      len = s.bytesize
      __fpga_putc(10) unless len > 0 && s.getbyte(len - 1) == 10
      i += 1
    end
    nil
  end

  # C: src/kernel.c mrb_print_m
  def print(*args)
    i = 0
    while i < __fpga_alen(args)
      __fpga_write_str(__fpga_aref(args, i).to_s)
      i += 1
    end
    nil
  end

  # C: picoruby-machine/src/mruby/machine.c print_sub
  def __fpga_write_str(s)
    p = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    k = 0
    while k < len
      __fpga_putc(__fpga_ld8(p + k))
      k += 1
    end
  end
end

class BasicObject
  # == / equal? は同じものか (class.c の mrb_obj_equal_m、即値は値で)
  # C: src/class.c mrb_obj_equal_m
  def ==(o)
    __fpga_tag(self) == __fpga_tag(o) && __fpga_int(self) == __fpga_int(o)
  end

  # C: src/class.c mrb_obj_equal_m
  def equal?(o)
    __fpga_tag(self) == __fpga_tag(o) && __fpga_int(self) == __fpga_int(o)
  end

  # != は == を送って反す (class.c の mrb_obj_not_equal_m)
  # C: src/class.c neq_iseq
  def !=(o)
    self == o ? false : true
  end

  # C: src/class.c mrb_bob_not
  def !
    self ? false : true
  end

  # 例外は V2d。それまでは止める (mruby は NoMethodError を上げる)
  # C: src/class.c mrb_obj_missing
  def method_missing(name, *args)
    __fpga_halt
  end
end
