# firmware: String・Array・nil・true・false の C の所 (mruby の src/string.c、src/array.c、src/object.c)
class String
  def to_s
    self
  end

  def bytesize
    __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
  end

  def getbyte(i)
    len = bytesize
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ld8(__fpga_ld32(__fpga_addr(self) + 16) + i) # L:S_PTR
  end
end

class Array
  def size
    __fpga_ld32(__fpga_addr(self) + 8) # L:A_LEN
  end

  def [](i)
    len = size
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ldv(__fpga_ld32(__fpga_addr(self) + 16) + i * 16) # L:A_PTR L:VALUE
  end
end

class NilClass
  def to_s
    ""
  end
end

class TrueClass
  def to_s
    "true"
  end
end

class FalseClass
  def to_s
    "false"
  end
end
