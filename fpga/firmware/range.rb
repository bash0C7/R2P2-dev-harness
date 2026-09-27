# firmware: Range (mruby の src/range.c、vm.c の OP_RANGE_INC / RANGE_EXC) と比べ方 (numeric.c の mrb_cmp、object.c の mrb_equal)。
# RRange は edges (beg と end の 2 つの値の領域) を別に持つ (layout.rb の RG_*)
class Object
  # C: src/vm.c OP_RANGE_INC
  def __fpga_op_RANGE_INC(a, b, c)
    __fpga_setreg(a, __fpga_range_new(__fpga_reg(a), __fpga_reg(a + 1), false))
  end

  # C: src/vm.c OP_RANGE_EXC
  def __fpga_op_RANGE_EXC(a, b, c)
    __fpga_setreg(a, __fpga_range_new(__fpga_reg(a), __fpga_reg(a + 1), true))
  end

  # C: src/range.c mrb_range_new
  def __fpga_range_new(beg, en, excl)
    __fpga_obj(__fpga_range_ptr_init(0, beg, en, excl))
  end

  # r が 0 なら新しく作る。作った後は初期化の印を付ける (2 度目は NameError)
  # C: src/range.c range_ptr_init
  def __fpga_range_ptr_init(r, beg, en, excl)
    __fpga_range_check(beg, en)
    if r > 0
      if __fpga_and(__fpga_ld32(r + 4), 4096) > 0 # L:H_FLAGS L:RANGE_INITIALIZED_FLAG (flags の bit 0 は語の 1 << 12)
        __fpga_name_error(__fpga_addr(:initialize), "'initialize' called twice", [])
      end
    else
      r = __fpga_slot(__fpga_image(12), 19) # L:IMG_range_class L:TT_RANGE
    end
    e = __fpga_alloc(32) # range_ptr_alloc_edges (VALUE 2 つ)
    __fpga_st32(r + 8, e) # L:RG_EDGES
    __fpga_stv(e, beg)
    __fpga_stv(e + 16, en) # L:VALUE
    __fpga_st32(r + 12, excl ? 1 : 0) # L:RG_EXCL
    __fpga_st32(r + 4, __fpga_or(__fpga_ld32(r + 4), 4096)) # L:H_FLAGS RANGE_INITIALIZED
    r
  end

  # 数同士は順序がある (NaN の端は順序が無いので ArgumentError)。nil の端は比べない。ほかは <=> で比べられなければ ArgumentError
  # C: src/range.c r_check
  def __fpga_range_check(a, b)
    ta = __fpga_tag(a)
    tb = __fpga_tag(b)
    if (ta == 3 || ta == 5) && (tb == 3 || tb == 5) # L:TAG_INT L:TAG_FLOAT
      return if (ta == 3 || __fpga_f64_nan_p(__fpga_int(a)) == false) && (tb == 3 || __fpga_f64_nan_p(__fpga_int(b)) == false) # L:TAG_INT
      __fpga_raise(ArgumentError, "bad value for range")
    end
    return if ta == 0 || tb == 0 # L:TAG_NIL
    __fpga_raise(ArgumentError, "bad value for range") if __fpga_cmp(a, b) == -2
  end

  # C: src/range.c RANGE_BEG
  def __fpga_range_beg(r)
    __fpga_ldv(__fpga_ld32(__fpga_addr(r) + 8)) # L:RG_EDGES
  end

  # C: src/range.c RANGE_END
  def __fpga_range_end(r)
    __fpga_ldv(__fpga_ld32(__fpga_addr(r) + 8) + 16) # L:RG_EDGES L:VALUE
  end

  # C: src/range.c RANGE_EXCL
  def __fpga_range_excl(r)
    __fpga_ld32(__fpga_addr(r) + 12) == 1 # L:RG_EXCL
  end

  # 整数の列の添字に当てる: [beg, len] (Range でなければ nil、範囲の外は false)
  # C: src/range.c mrb_range_beg_len
  def __fpga_range_beg_len(range, len, trunc)
    return nil unless __fpga_tag(range) == 7 && __fpga_tt(__fpga_addr(range)) == 19 # L:TAG_OBJ L:TT_RANGE MRB_RANGE_TYPE_MISMATCH
    b = __fpga_range_beg(range)
    e = __fpga_range_end(range)
    beg = __fpga_tag(b) == 0 ? 0 : __fpga_as_int(b) # L:TAG_NIL
    en = __fpga_tag(e) == 0 ? -1 : __fpga_as_int(e) # L:TAG_NIL
    excl = __fpga_tag(e) == 0 ? false : __fpga_range_excl(range) # L:TAG_NIL
    if beg < 0
      beg += len
      return false if beg < 0 # MRB_RANGE_OUT
    end
    if trunc
      return false if beg > len
      en = len if en > len
    end
    en += len if en < 0
    en += 1 if excl == false && (trunc == false || en < len)
    n = en - beg
    n = 0 if n < 0
    [beg, n]
  end

  # C: include/mruby.h mrb_as_int
  def __fpga_as_int(v)
    return v if __fpga_tag(v) == 3 # L:TAG_INT
    return __fpga_float_to_integer(v) if __fpga_tag(v) == 5 # L:TAG_FLOAT mrb_ensure_integer_type
    __fpga_raisef(TypeError, "%Y cannot be converted to Integer", [v]) # mrb_ensure_integer_type
  end

  # C: src/numeric.c mrb_float_to_integer
  def __fpga_float_to_integer(x)
    __fpga_raise(TypeError, "non float value") unless __fpga_tag(x) == 5 # L:TAG_FLOAT
    f = __fpga_int(x)
    __fpga_raisef(RangeError, "float %f out of range", [x]) if __fpga_f64_inf_p(f) || __fpga_f64_nan_p(f)
    __fpga_flo_to_i(x)
  end

  # 0、1、-1、比べられなければ -2
  # C: src/numeric.c mrb_cmp
  def __fpga_cmp(a, b)
    t = __fpga_tag(a)
    return __fpga_cmpnum_total(a, b) if t == 3 || t == 5 # L:TAG_INT L:TAG_FLOAT
    if t == 7 && __fpga_tt(__fpga_addr(a)) == 18 # L:TAG_OBJ L:TT_STRING
      return -2 unless __fpga_tag(b) == 7 && __fpga_tt(__fpga_addr(b)) == 18 # L:TAG_OBJ L:TT_STRING
      return a <=> b # mrb_str_cmp (String#<=> と同じ関数)
    end
    v = a <=> b
    return -2 unless __fpga_tag(v) == 3 # L:TAG_INT
    v
  end

  # identical か、== が真 (mrb_equal_in_c の近道は見える意味を変えない)
  # C: src/object.c mrb_equal
  def __fpga_equal(a, b)
    return true if __fpga_tag(a) == __fpga_tag(b) && __fpga_int(a) == __fpga_int(b) # mrb_obj_eq
    a == b ? true : false
  end
end

class Range
  # C: src/range.c range_beg
  def begin
    __fpga_range_beg(self)
  end

  alias first begin # range.c は begin と first に同じ関数 range_beg を置く

  # C: src/range.c range_end
  def end
    __fpga_range_end(self)
  end

  alias last end # range.c は end と last に同じ関数 range_end を置く

  # C: src/range.c range_excl
  def exclude_end?
    __fpga_range_excl(self)
  end

  # C: src/range.c range_initialize
  def initialize(*args)
    __fpga_check_argc(args, 2, 3) # MRB_ARGS_ANY の後の mrb_get_args の oo|b
    ex = __fpga_alen(args) == 3 ? __fpga_aref(args, 2) : false
    __fpga_range_ptr_init(__fpga_addr(self), __fpga_aref(args, 0), __fpga_aref(args, 1), ex ? true : false) # frozen の印は S5
    self
  end

  # C: src/range.c range_eq
  def ==(obj)
    return true if __fpga_tag(obj) == 7 && __fpga_addr(obj) == __fpga_addr(self) # L:TAG_OBJ mrb_obj_equal
    return false unless __fpga_addr(__fpga_obj_class(obj)) == __fpga_addr(__fpga_obj_class(self)) # mrb_obj_is_instance_of
    return false unless __fpga_equal(__fpga_range_beg(self), __fpga_range_beg(obj))
    return false unless __fpga_equal(__fpga_range_end(self), __fpga_range_end(obj))
    __fpga_range_excl(self) == __fpga_range_excl(obj)
  end

  # C: src/range.c range_include
  def include?(val)
    beg = __fpga_range_beg(self)
    en = __fpga_range_end(self)
    if __fpga_tag(beg) == 0 # L:TAG_NIL
      c = __fpga_cmp(en, val)
      return true if __fpga_range_excl(self) ? c == 1 : (c == 0 || c == 1) # r_gt / r_ge
    else
      c = __fpga_cmp(beg, val)
      if c == 0 || c == -1 # r_le
        return true if __fpga_tag(en) == 0 # L:TAG_NIL
        c = __fpga_cmp(en, val)
        return true if __fpga_range_excl(self) ? c == 1 : (c == 0 || c == 1)
      end
    end
    false
  end

  alias === include? # range.c は ===、include?、member? に同じ関数 range_include を置く
  alias member? include?

  # C: src/range.c range_to_s
  def to_s
    str = __fpga_obj_as_string(__fpga_range_beg(self))
    str2 = __fpga_obj_as_string(__fpga_range_end(self))
    s = __fpga_str_new(__fpga_ld32(__fpga_addr(str) + 16), __fpga_ld32(__fpga_addr(str) + 8)) # L:S_PTR L:S_LEN mrb_str_dup
    __fpga_str_cat_str(s, __fpga_range_excl(self) ? "..." : "..")
    __fpga_str_cat_str(s, str2)
  end

  # C: src/range.c range_inspect
  def inspect
    beg = __fpga_range_beg(self)
    en = __fpga_range_end(self)
    if __fpga_tag(beg) == 0 # L:TAG_NIL
      s = __fpga_range_excl(self) ? "..." : ".." # mrb_str_new (文字列の literal は毎回新しい)
    else
      str = __fpga_inspect(beg)
      s = __fpga_str_new(__fpga_ld32(__fpga_addr(str) + 16), __fpga_ld32(__fpga_addr(str) + 8)) # L:S_PTR L:S_LEN mrb_str_dup
      __fpga_str_cat_str(s, __fpga_range_excl(self) ? "..." : "..")
    end
    __fpga_str_cat_str(s, __fpga_inspect(en)) unless __fpga_tag(en) == 0 # L:TAG_NIL
    s
  end
end
