# firmware: String・Array・nil・true・false の C の所 (mruby の src/string.c、src/array.c、src/object.c)
class String
  # C: src/string.c mrb_str_to_s
  def to_s
    self
  end

  # C: src/string.c mrb_str_bytesize
  def bytesize
    __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
  end

  # size / length (string.c の mrb_str_size、MRB_UTF8_STRING): 文字の数 = 続きのバイト (10xxxxxx) でないバイトの数
  # C: src/string.c mrb_str_size
  def size
    p = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    n = 0
    k = 0
    while k < len
      n += 1 unless __fpga_and(__fpga_ld8(p + k), 192) == 128
      k += 1
    end
    n
  end

  alias length size # string.c は size と length に同じ関数 mrb_str_size を置く

  # + (string.c の mrb_str_plus)
  # C: src/string.c mrb_str_plus_m
  def +(other)
    __fpga_halt unless __fpga_tag(other) == 7 && __fpga_tt(__fpga_addr(other)) == 18 # TypeError (V2d) L:TT_STRING
    a = __fpga_addr(self)
    b = __fpga_addr(other)
    la = __fpga_ld32(a + 8) # L:S_LEN
    lb = __fpga_ld32(b + 8)
    buf = __fpga_alloc(la + lb + 1)
    __fpga_copy(buf, __fpga_ld32(a + 16), la) # L:S_PTR
    __fpga_copy(buf + la, __fpga_ld32(b + 16), lb)
    __fpga_str_new(buf, la + lb)
  end

  # C: src/string.c mrb_str_intern
  def to_sym
    __fpga_mkval(4, __fpga_intern_str(self)) # L:TAG_SYM
  end

  # C: src/string.c mrb_str_getbyte
  def getbyte(i)
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ld8(__fpga_ld32(__fpga_addr(self) + 16) + i) # L:S_PTR
  end
end

class Symbol
  # to_s / id2name (symbol.c): シンボル表の名前から新しい String
  # C: src/symbol.c sym_to_s
  def to_s
    tab = __fpga_image(26) # L:IMG_symtbl
    i = __fpga_addr(self)
    __fpga_str_new(__fpga_ld32(tab + i * 8), __fpga_ld32(tab + i * 8 + 4))
  end
end

class Array
  # C: src/array.c mrb_ary_size
  def size
    __fpga_ld32(__fpga_addr(self) + 8) # L:A_LEN
  end

  # push / << (array.c の mrb_ary_push): 容量が足りなければ倍の領域に写す
  # C: src/array.c mrb_ary_push_m
  def push(*vals)
    k = 0
    while k < __fpga_alen(vals)
      __fpga_push1(__fpga_aref(vals, k))
      k += 1
    end
    self
  end

  # C: src/array.c mrb_ary_push_m
  def <<(v)
    __fpga_push1(v)
    self
  end

  # C: src/array.c mrb_ary_push
  def __fpga_push1(v)
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

  # C: src/array.c mrb_ary_aget
  def [](i)
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:A_LEN
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ldv(__fpga_ld32(__fpga_addr(self) + 16) + i * 16) # L:A_PTR L:VALUE
  end
end

class NilClass
  # C: src/object.c nil_to_s
  def to_s
    ""
  end

  # C: src/object.c mrb_true
  def nil?
    true
  end
end

class TrueClass
  # C: src/object.c true_to_s
  def to_s
    "true"
  end
end

class FalseClass
  # C: src/object.c false_to_s
  def to_s
    "false"
  end
end

class Object
  # 配列の長さと要素を、メソッドを送らずに読む (C の RARRAY_LEN / RARRAY_PTR。firmware の残りの引数に使う)
  # C: include/mruby/array.h RARRAY_LEN
  def __fpga_alen(a)
    __fpga_ld32(__fpga_addr(a) + 8) # L:A_LEN
  end

  # C: include/mruby/array.h RARRAY_PTR
  def __fpga_aref(a, i)
    __fpga_ldv(__fpga_ld32(__fpga_addr(a) + 16) + i * 16) # L:A_PTR L:VALUE
  end
end
