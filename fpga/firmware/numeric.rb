# firmware: Integer の C の所 (mruby の src/numeric.c)。四則と比較は回路の命令 (整数同士)。
# Float と混ざる所は float.rb の helper (soft-float、D50) を使う
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

  # >> (右 shift は mrb_num_shift に負の幅で)
  # C: src/numeric.c int_rshift
  def >>(w)
    width = __fpga_as_int(w)
    return self if width == 0
    __fpga_raise(RangeError, "integer overflow in bit shift") if width == -9223372036854775807 - 1 # MRB_INT_MIN mrb_int_overflow
    val = self
    return self if val == 0
    __fpga_num_shift(val, 0 - width)
  end

  # C: src/numeric.c int_rev
  def ~
    __fpga_xor(self, -1)
  end

  # C: src/numeric.c int_ceil
  def ceil(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    f = __fpga_prepare_int_rounding(args)
    return 0 if f == 0 # undef
    return self if __fpga_tag(f) == 0 # L:TAG_NIL
    a = self
    c = __fpga_rem(a, f)
    return self if c == 0
    neg = a < 0
    a -= c
    unless neg
      __fpga_raise(RangeError, "integer overflow in ceil") if __fpga_int_add_overflow(a, f) # mrb_int_overflow
      a += f
    end
    a
  end

  # C: src/numeric.c int_floor
  def floor(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    f = __fpga_prepare_int_rounding(args)
    return 0 if f == 0 # undef
    return self if __fpga_tag(f) == 0 # L:TAG_NIL
    a = self
    c = __fpga_rem(a, f)
    return self if c == 0
    neg = a < 0
    a -= c
    if neg
      __fpga_raise(RangeError, "integer overflow in floor") if __fpga_int_sub_overflow(a, f) # mrb_int_overflow
      a -= f
    end
    a
  end

  # 負の桁で丸める。0.5 は 0 から遠い方へ
  # C: src/numeric.c int_round
  def round(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    f = __fpga_prepare_int_rounding(args)
    return 0 if f == 0 # undef
    return self if __fpga_tag(f) == 0 # L:TAG_NIL
    a = self
    b = f
    c = __fpga_rem(a, b) # C の %
    half = b / 2
    a -= c
    if c < 0
      return a if 0 - c < half
      __fpga_raise(RangeError, "integer overflow in round") if __fpga_int_sub_overflow(a, b) # mrb_int_overflow
      return a - b
    end
    return a if c < half
    __fpga_raise(RangeError, "integer overflow in round") if __fpga_int_add_overflow(a, b)
    a + b
  end

  # C: src/numeric.c int_truncate
  def truncate(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    f = __fpga_prepare_int_rounding(args)
    return 0 if f == 0 # undef
    return self if __fpga_tag(f) == 0 # L:TAG_NIL
    a = self
    a - __fpga_rem(a, f)
  end

  # C: src/numeric.c int_s_ensure
  def self.__ensure(val)
    __fpga_as_int(val) # mrb_ensure_int_type
  end

  # C: src/numeric.c int_to_f
  def to_f
    __fpga_float_value(__fpga_f64_from_int(self))
  end

  # C: src/numeric.c mrb_obj_itself
  def to_i
    self
  end

  # C: src/numeric.c mrb_obj_itself
  def to_int
    self
  end

  # C: src/numeric.c int_hash
  def hash
    __fpga_byte_hash8(self) # mrb_byte_hash (8 バイトを host の記憶の並びで)
  end

  # step の数え手: 刻みが Float なら self を Float に (C は ci->mid を 0 にして backtrace から隠す。backtrace は D41)
  # C: src/numeric.c coerce_step_counter
  def __coerce_step_counter(step)
    return __fpga_float_value(__fpga_as_float(self)) if __fpga_tag(step) == 5 # L:TAG_FLOAT mrb_ensure_float_type
    self
  end

  # % (floor の剰余)。Float は flodivmod
  # C: src/numeric.c int_mod
  def %(y)
    a = self
    return self if a == 0
    if __fpga_tag(y) == 3 # L:TAG_INT
      b = y
      __fpga_raise(ZeroDivisionError, "divided by 0") if b == 0 # mrb_int_zerodiv
      return 0 if a == -9223372036854775807 - 1 && b == -1 # MRB_INT_MIN
      mod = __fpga_rem(a, b)
      mod += b if ((a < 0) == (b < 0)) == false && (mod == 0) == false
      return mod
    end
    __fpga_float_value(__fpga_aref(__fpga_flodivmod(__fpga_f64_from_int(a), __fpga_as_float(y), false), 1))
  end

  # C: src/numeric.c int_divmod
  def divmod(y)
    if __fpga_tag(y) == 3 # L:TAG_INT
      r = __fpga_intdivmod(self, y)
      return r # mrb_assoc_new
    end
    x = __fpga_float_value(__fpga_as_float(self)) # flo_divmod(mrb_ensure_float_type(x))
    r = __fpga_flodivmod(__fpga_int(x), __fpga_as_float(y), true)
    div = __fpga_aref(r, 0)
    a = __fpga_fixable_float(div) ? __fpga_f64_to_int(div) : __fpga_float_value(div)
    [a, __fpga_float_value(__fpga_aref(r, 1))]
  end

  # bit_op: 整数でない相手は TypeError
  # C: src/numeric.c int_and
  def &(y)
    __fpga_int_noconv(y) unless __fpga_tag(y) == 3 # L:TAG_INT
    __fpga_and(self, y)
  end

  # C: src/numeric.c int_or
  def |(y)
    __fpga_int_noconv(y) unless __fpga_tag(y) == 3 # L:TAG_INT
    __fpga_or(self, y)
  end

  # C: src/numeric.c int_xor
  def ^(y)
    __fpga_int_noconv(y) unless __fpga_tag(y) == 3 # L:TAG_INT
    __fpga_xor(self, y)
  end

  # 四則と比較のメソッド。self が受け手の式と send から呼ばれる。整数どうしは局所変数の式 (回路の命令 ADD、EQ ...) で、
  # 桁あふれは C と同じ文言で先に調べる
  # C: src/numeric.c int_equal
  def ==(y)
    t = __fpga_tag(y)
    if t == 3 # L:TAG_INT
      x = self
      return x == y
    end
    return __fpga_int_float_cmp(self, __fpga_int(y)) == 0 if t == 5 # L:TAG_FLOAT
    false
  end

  # C: src/numeric.c int_add
  def +(y)
    a = self
    if __fpga_tag(y) == 3 # L:TAG_INT mrb_int_add
      return y if a == 0
      return self if y == 0
      __fpga_raise(RangeError, "integer overflow in addition") if __fpga_int_add_overflow(a, y) # mrb_int_overflow
      return a + y
    end
    __fpga_float_value(__fpga_f64_add(__fpga_f64_from_int(a), __fpga_as_float(y)))
  end

  # C: src/numeric.c int_sub
  def -(y)
    a = self
    if __fpga_tag(y) == 3 # L:TAG_INT mrb_int_sub
      __fpga_raise(RangeError, "integer overflow in subtraction") if __fpga_int_sub_overflow(a, y) # mrb_int_overflow
      return a - y
    end
    __fpga_float_value(__fpga_f64_sub(__fpga_f64_from_int(a), __fpga_as_float(y)))
  end

  # C: src/numeric.c int_mul
  def *(y)
    a = self
    if __fpga_tag(y) == 3 # L:TAG_INT mrb_int_mul
      return self if a == 0
      return y if a == 1
      b = y
      return y if b == 0
      return self if b == 1
      __fpga_raise(RangeError, "integer overflow in multiplication") if __fpga_int_mul_overflow(a, b) # mrb_int_overflow
      return a * b
    end
    __fpga_int_noconv(y) unless __fpga_tag(y) == 5 # L:TAG_FLOAT
    __fpga_float_value(__fpga_f64_mul(__fpga_f64_from_int(a), __fpga_as_float(y)))
  end

  # C: src/numeric.c int_div
  def /(y)
    return __fpga_div_int_value(self, y) if __fpga_tag(y) == 3 # L:TAG_INT
    __fpga_int_noconv(y) unless __fpga_tag(y) == 5 # L:TAG_FLOAT
    __fpga_float_value(__fpga_div_float(__fpga_as_float(self), __fpga_as_float(y)))
  end

  # C: src/numeric.c int_idiv
  def div(y)
    __fpga_div_int_value(self, __fpga_as_int(y))
  end

  # C: src/numeric.c int_fdiv
  def fdiv(y)
    y = __fpga_as_float(y)
    __fpga_raise(ZeroDivisionError, "divided by 0") if __fpga_f64_cmp(y, 0) == 0 # mrb_int_zerodiv
    __fpga_float_value(__fpga_f64_div(__fpga_f64_from_int(self), y))
  end

  # MRB_USE_RATIONAL の無い build は int_fdiv
  # C: src/numeric.c int_quo
  def quo(y)
    y = __fpga_as_float(y)
    __fpga_raise(ZeroDivisionError, "divided by 0") if __fpga_f64_cmp(y, 0) == 0 # mrb_int_zerodiv
    __fpga_float_value(__fpga_f64_div(__fpga_f64_from_int(self), y))
  end

  # C: src/numeric.c int_pow
  def **(y)
    __fpga_int_pow(self, y)
  end

  # C: src/numeric.c num_cmp
  def <=>(other)
    n = __fpga_cmpnum(self, other)
    return nil if n == -2 || n == -3
    n
  end

  # C: src/numeric.c num_lt
  def <(other)
    n = __fpga_cmpnum(self, other)
    return false if n == -3
    __fpga_raisef(ArgumentError, "comparison of %t with %t failed", [self, other]) if n == -2 # cmperr
    n < 0
  end

  # C: src/numeric.c num_le
  def <=(other)
    n = __fpga_cmpnum(self, other)
    return false if n == -3
    __fpga_raisef(ArgumentError, "comparison of %t with %t failed", [self, other]) if n == -2
    n <= 0
  end

  # C: src/numeric.c num_gt
  def >(other)
    n = __fpga_cmpnum(self, other)
    return false if n == -3
    __fpga_raisef(ArgumentError, "comparison of %t with %t failed", [self, other]) if n == -2
    n > 0
  end

  # C: src/numeric.c num_ge
  def >=(other)
    n = __fpga_cmpnum(self, other)
    return false if n == -3
    __fpga_raisef(ArgumentError, "comparison of %t with %t failed", [self, other]) if n == -2
    n >= 0
  end
end

class Object
  # 10 の -nd 乗 (nd >= 0 なら nil、mrb_int に入らないほど負なら undef の印 0)。args は mrb_get_args の "|i"
  # C: src/numeric.c prepare_int_rounding
  def __fpga_prepare_int_rounding(args)
    nd = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : 0
    bytes = __fpga_int(7.875) # (double)sizeof(mrb_int) - 0.125
    return nil if nd >= 0
    return 0 if __fpga_f64_cmp(__fpga_f64_mul(__fpga_int(-0.415241), __fpga_f64_from_int(nd)), bytes) > 0 # undef
    __fpga_int_pow(10, 0 - nd)
  end

  # C: src/numeric.c mrb_int_pow
  def __fpga_int_pow(x, y)
    base = x
    result = 1
    if __fpga_tag(y) == 5 # L:TAG_FLOAT
      return __fpga_float_value(__fpga_f64_pow(__fpga_f64_from_int(base), __fpga_int(y)))
    elsif __fpga_tag(y) == 3 # L:TAG_INT
      exp = y
    else
      exp = __fpga_as_int(y)
    end
    return __fpga_float_value(__fpga_f64_pow(__fpga_f64_from_int(base), __fpga_f64_from_int(exp))) if exp < 0
    while true
      if __fpga_and(exp, 1) == 1
        __fpga_raise(RangeError, "integer overflow in power") if __fpga_int_mul_overflow(result, base) # mrb_int_overflow
        result *= base
      end
      exp = __fpga_shr(exp, 1)
      break if exp == 0
      __fpga_raise(RangeError, "integer overflow in power") if __fpga_int_mul_overflow(base, base)
      base *= base
    end
    result
  end

  # C: include/mruby/numeric.h mrb_int_add_overflow
  def __fpga_int_add_overflow(a, b)
    (b > 0 && a > 9223372036854775807 - b) || (b < 0 && a < -9223372036854775807 - 1 - b)
  end

  # C: include/mruby/numeric.h mrb_int_sub_overflow
  def __fpga_int_sub_overflow(a, b)
    (b < 0 && a > 9223372036854775807 + b) || (b > 0 && a < -9223372036854775807 - 1 + b)
  end

  # MRB_INT64 の形 (__builtin_mul_overflow の無い時の写し)。C の / は 0 に向けて切る
  # C: include/mruby/numeric.h mrb_int_mul_overflow
  def __fpga_int_mul_overflow(a, b)
    min = -9223372036854775807 - 1
    return true if a > 0 && b > 0 && a > __fpga_div_trunc(9223372036854775807, b)
    return true if a < 0 && b > 0 && a < __fpga_div_trunc(min, b)
    return true if a > 0 && b < 0 && b < __fpga_div_trunc(min, a)
    return true if a < 0 && b < 0 && (a <= min || b <= min || 0 - a > __fpga_div_trunc(9223372036854775807, 0 - b))
    false
  end

  # C の / (0 に向けて切る)。y は 0 でなく、MRB_INT_MIN / -1 でない
  # C: none (D17)
  def __fpga_div_trunc(x, y)
    (x - __fpga_rem(x, y)) / y
  end

  # C: src/numeric.c mrb_div_int_value
  def __fpga_div_int_value(x, y)
    __fpga_raise(ZeroDivisionError, "divided by 0") if y == 0 # mrb_int_zerodiv
    __fpga_raise(RangeError, "integer overflow in division") if x == -9223372036854775807 - 1 && y == -1 # mrb_int_overflow
    x / y # mrb_div_int (floor の商は回路の DIV)
  end

  # [div, mod] (floor の商と剰余)
  # C: src/numeric.c intdivmod
  def __fpga_intdivmod(x, y)
    __fpga_raise(ZeroDivisionError, "divided by 0") if y == 0 # mrb_int_zerodiv
    __fpga_raise(RangeError, "integer overflow in division") if x == -9223372036854775807 - 1 && y == -1 # mrb_int_overflow
    mod = __fpga_rem(x, y)
    div = (x - mod) / y # x / y (0 に向けて切る)
    if __fpga_xor(x, y) < 0 && (mod == 0) == false
      mod += y
      div -= 1
    end
    [div, mod]
  end

  # C: src/numeric.c mrb_int_noconv
  def __fpga_int_noconv(y)
    __fpga_raisef(TypeError, "can't convert %Y into Integer", [y])
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
