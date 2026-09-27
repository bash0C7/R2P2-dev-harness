# firmware: String・Array・nil・true・false の C の所 (mruby の src/string.c、src/array.c、src/object.c)
class String
  def to_s
    self
  end

  def bytesize
    __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
  end

  # + (string.c の mrb_str_plus)
  def +(other)
    __fpga_halt unless __fpga_tag(other) == 7 && __tt(__fpga_addr(other)) == 18 # TypeError (V2d) L:TT_STRING
    a = __fpga_addr(self)
    b = __fpga_addr(other)
    la = __fpga_ld32(a + 8) # L:S_LEN
    lb = __fpga_ld32(b + 8)
    buf = __fpga_alloc(la + lb + 1)
    __fpga_copy(buf, __fpga_ld32(a + 16), la) # L:S_PTR
    __fpga_copy(buf + la, __fpga_ld32(b + 16), lb)
    __str_new(buf, la + lb)
  end

  def to_sym
    __fpga_mkval(4, __intern_str(self)) # L:TAG_SYM
  end

  def getbyte(i)
    len = bytesize
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ld8(__fpga_ld32(__fpga_addr(self) + 16) + i) # L:S_PTR
  end
end

class Symbol
  # to_s / id2name (symbol.c): シンボル表の名前から新しい String
  def to_s
    tab = __fpga_image(4) # L:IMG_sym_table
    i = __fpga_addr(self)
    __str_new(__fpga_ld32(tab + i * 8), __fpga_ld32(tab + i * 8 + 4))
  end
end

class Array
  def size
    __fpga_ld32(__fpga_addr(self) + 8) # L:A_LEN
  end

  # push / << (array.c の mrb_ary_push): 容量が足りなければ倍の領域に写す
  def push(*vals)
    k = 0
    while k < vals.size
      __push1(vals[k])
      k += 1
    end
    self
  end

  def <<(v)
    __push1(v)
    self
  end

  def __push1(v)
    a = __fpga_addr(self)
    len = __fpga_ld32(a + 8) # L:A_LEN
    capa = __fpga_ld32(a + 12) # L:A_CAPA
    if len >= capa
      capa = capa * 2 + 4
      buf = __fpga_alloc(capa * 16) # L:VALUE
      __fpga_copy(buf, __fpga_ld32(a + 16), len * 16) # L:A_PTR
      __fpga_st32(a + 16, buf)
      __fpga_st32(a + 12, capa)
    end
    __fpga_stv(__fpga_ld32(a + 16) + len * 16, v)
    __fpga_st32(a + 8, len + 1)
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

  def nil?
    true
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
