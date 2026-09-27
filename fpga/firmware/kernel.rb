# firmware: Kernel の C の所 (mruby の src/kernel.c、picoruby-machine の Kernel#puts / print は IO を通すが、FPGA はコンソールの
# primitive に直接書く) と BasicObject#method_missing (src/class.c、src/error.c)。
module Kernel
  # puts (mruby の mrblib には無く、picoruby-machine の kernel.rb が $stdout に渡す。改行で終わらなければ改行を足す)
  def puts(*args)
    n = args.size
    if n == 0
      __fpga_putc(10)
      return nil
    end
    i = 0
    while i < n
      s = args[i].to_s
      __write_str(s)
      len = s.bytesize
      __fpga_putc(10) unless len > 0 && s.getbyte(len - 1) == 10
      i += 1
    end
    nil
  end

  def print(*args)
    i = 0
    while i < args.size
      __write_str(args[i].to_s)
      i += 1
    end
    nil
  end

  def __write_str(s)
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
  # 例外は V2d。それまでは止める (mruby は NoMethodError を上げる)
  def method_missing(name, *args)
    __fpga_halt
  end
end
