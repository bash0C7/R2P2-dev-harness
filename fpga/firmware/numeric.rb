# firmware: Integer の C の所 (mruby の src/numeric.c)。四則と比較は回路の命令 (整数同士)
class Integer
  # to_s / inspect (numeric.c の int_to_s と mrb_integer_to_str、mrb_int_to_cstr)。基数は 2〜36。
  # INT_MIN は符号を反せないので、負の数は負のまま 0 に向けて割る
  # C: src/numeric.c int_to_s
  def to_s(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    base = __fpga_alen(args) > 0 ? __fpga_aref(args, 0) : 10 # mrb_integer (変換しない)
    __fpga_raisef(ArgumentError, "invalid radix %i", [base]) if base < 2 || 36 < base
    x = self
    return "0" if x == 0
    digits = "0123456789abcdefghijklmnopqrstuvwxyz" # mrb_digitmap
    dp = __fpga_ld32(__fpga_addr(digits) + 16) # L:S_PTR
    neg = x < 0
    buf = __fpga_alloc(66)
    k = 66
    until x == 0
      d = __fpga_rem(x, base) # 負の数なら -(base-1)..0
      x = (x - d) / base
      k -= 1
      __fpga_st8(buf + k, __fpga_ld8(dp + (neg ? 0 - d : d)))
    end
    if neg
      k -= 1
      __fpga_st8(buf + k, 45)
    end
    __fpga_str_new(buf + k, 66 - k)
  end

  alias inspect to_s # numeric.c は to_s と inspect に同じ関数 int_to_s を置く

  # C: src/numeric.c int_lshift
  def <<(w)
    width = __fpga_as_int(w)
    return self if width == 0
    __fpga_raise(RangeError, "integer overflow in bit shift") if width == -9223372036854775807 - 1 # MRB_INT_MIN mrb_int_overflow
    val = self
    return self if val == 0
    __fpga_num_shift(val, width)
  end

  # C: src/numeric.c mrb_num_shift
  def __fpga_num_shift(val, width)
    if width < 0 # 右へ
      return val < 0 ? -1 : 0 if 0 - width >= 63 # NUMERIC_SHIFT_WIDTH_MAX
      return __fpga_shr_s(val, 0 - width)
    end
    if val > 0
      __fpga_raise(RangeError, "integer overflow in bit shift") if width > 63 || val > __fpga_shr_s(9223372036854775807, width) # MRB_INT_MAX
      return __fpga_shl(val, width)
    end
    __fpga_raise(RangeError, "integer overflow in bit shift") if width > 63 || val < __fpga_shr_s(-9223372036854775807 - 1, width) # MRB_INT_MIN
    return -9223372036854775807 - 1 if width == 63
    val * __fpga_shl(1, width)
  end

  # 符号付きの右 shift (C の >> を mrb_int に)
  # C: src/numeric.c mrb_num_shift
  def __fpga_shr_s(val, n)
    return __fpga_shr(val, n) if val >= 0
    -1 - __fpga_shr(-1 - val, n) # ~(~val >> n)
  end

  # round (numeric.c の int_round と prepare_int_rounding): 負の桁で丸める。0.5 は 0 から遠い方へ
  # C: src/numeric.c int_round
  def round(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    nd = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : 0
    return self if nd >= 0
    return 0 if nd <= -19 # -0.415241 * nd > sizeof(mrb_int) - 0.125
    b = 1
    k = 0
    while k < 0 - nd # mrb_int_pow(10, -nd)
      b *= 10
      k += 1
    end
    a = self
    c = __fpga_rem(a, b) # C の %
    half = b / 2
    a -= c
    if c < 0
      return a if 0 - c < half
      __fpga_raise(RangeError, "integer overflow in round") if a < -9223372036854775807 - 1 + b # mrb_int_sub_overflow
      return a - b
    end
    return a if c < half
    __fpga_raise(RangeError, "integer overflow in round") if a > 9223372036854775807 - b # mrb_int_add_overflow
    a + b
  end

  # % (numeric.c の int_mod、floor の剰余): 0 に向けて切った剰余を、符号が割る数と違えば割る数を足す
  # C: src/numeric.c int_mod
  def %(y)
    x = self
    return x / 0 if y == 0 # ZeroDivisionError (回路の DIV の罠)
    r = __fpga_rem(x, y)
    r += y if (r == 0) == false && ((r < 0) == (y < 0)) == false
    r
  end

  # C: src/numeric.c int_and
  def &(y)
    __fpga_and(self, y)
  end

  # C: src/numeric.c int_or
  def |(y)
    __fpga_or(self, y)
  end

  # C: src/numeric.c int_xor
  def ^(y)
    __fpga_xor(self, y)
  end

  # 四則と比較のメソッド (numeric.c の int_plus ... int_equal)。self が受け手の式と send から呼ばれる。
  # 局所変数同士にすると回路の命令 (ADD、EQ ...) になる。整数でない相手 (Float) は S5f
  # C: src/numeric.c int_equal
  def ==(y)
    return false unless __fpga_tag(y) == 3 # L:TAG_INT
    x = self
    x == y
  end

  # C: src/numeric.c int_add
  def +(y)
    x = self
    x + y
  end

  # C: src/numeric.c int_sub
  def -(y)
    x = self
    x - y
  end

  # C: src/numeric.c int_mul
  def *(y)
    x = self
    x * y
  end

  # C: src/numeric.c int_div
  def /(y)
    x = self
    x / y
  end

  # C: src/numeric.c num_lt
  def <(y)
    x = self
    x < y
  end

  # C: src/numeric.c num_le
  def <=(y)
    x = self
    x <= y
  end

  # C: src/numeric.c num_gt
  def >(y)
    x = self
    x > y
  end

  # C: src/numeric.c num_ge
  def >=(y)
    x = self
    x >= y
  end
end

class Integer
  # 64bit の値の 8 バイトの FNV-1a
  # C: src/numeric.c int_hash
  def hash
    __fpga_int64_byte_hash(self)
  end
end

class Float
  # -0.0 は 0.0 にそろえて double の 8 バイトの FNV-1a
  # C: src/numeric.c flo_hash
  def hash
    bits = __fpga_int(self)
    bits = 0 if bits == __fpga_shl(1, 63) # -0.0 (f == 0)
    __fpga_int64_byte_hash(bits)
  end
end

class Numeric
  # 型も値も同じ (1.eql?(1.0) は偽)。Integer と Float 以外の Numeric は同じ型で ==
  # C: src/numeric.c num_eql
  def eql?(y)
    x = self
    if __fpga_tag(x) == 5 # L:TAG_FLOAT
      return false unless __fpga_tag(y) == 5 # L:TAG_FLOAT
      return __fpga_float_eq(x, y)
    end
    if __fpga_tag(x) == 3 # L:TAG_INT
      return false unless __fpga_tag(y) == 3 # L:TAG_INT
      return x == y
    end
    return false unless __fpga_tag(x) == __fpga_tag(y) && (__fpga_tag(x) < 7 || __fpga_tt(__fpga_addr(x)) == __fpga_tt(__fpga_addr(y))) # L:TAG_OBJ mrb_type
    __fpga_equal(x, y)
  end
end
