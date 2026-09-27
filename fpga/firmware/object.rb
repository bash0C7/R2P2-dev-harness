# firmware: Kernel と nil / true / false の C の所 (mruby の src/kernel.c、src/object.c、src/class.c の init_copy と mrb_obj_dup、
# src/etc.c の mrb_obj_id、src/string.c の mrb_ptr_to_str)。番地の数 (to_s、__id__) は板の番地なので host と違う (D02)
class Object
  # 16 進の番地 "0x..." (小文字、先頭の 0 無し)
  # C: src/string.c mrb_ptr_to_str
  def __fpga_ptr_to_str(n)
    digits = "0123456789abcdef"
    buf = __fpga_alloc(16)
    len = 0
    while true # 下の桁から
      __fpga_st8(buf + len, __fpga_ld8(__fpga_ld32(__fpga_addr(digits) + 16) + __fpga_and(n, 15))) # L:S_PTR
      len += 1
      n = __fpga_shr(n, 4)
      break if n == 0
    end
    s = "0x"
    while len > 0
      len -= 1
      __fpga_str_cat(s, buf + len, 1)
    end
    s
  end

  # obj の sym のメソッドが、firmware の owner#sym (C の関数 func の写し) と同じか
  # C: src/class.c mrb_func_basic_p
  def __fpga_func_basic_p(obj, sym, owner)
    e = __fpga_search(__fpga_addr(__fpga_class_of(obj)), sym)
    e > 0 && __fpga_and(e, -4) == __fpga_and(__fpga_search(__fpga_addr(owner), sym), -4) # L:VIS_MASK (~3)
  end

  # main の to_s と inspect (class.c の mrb_init_class が top_self の特異メソッドにする)。起動が __fpga_init_main で main に付ける
  # C: src/class.c inspect_main
  def __fpga_inspect_main
    "main"
  end

  # C: src/class.c mrb_init_class
  def __fpga_init_main
    main = __fpga_obj(__fpga_image(4)) # L:IMG_top_self
    m = __fpga_search(__fpga_addr(Object), __fpga_addr(:__fpga_inspect_main))
    sc = __fpga_singleton(main)
    __fpga_define(sc, __fpga_addr(:inspect), __fpga_and(m, -4), 0) # L:VIS_MASK (~3) L:VIS_PUBLIC
    __fpga_define(sc, __fpga_addr(:to_s), __fpga_and(m, -4), 0)
  end

  # C: src/object.c mrb_any_to_s
  def __fpga_any_to_s(obj)
    str = "#<"
    __fpga_str_cat_str(str, __fpga_mod_to_s(__fpga_obj_class(obj))) # mrb_obj_classname
    if __fpga_tag(obj) == 7 # L:TAG_OBJ mrb_immediate_p でない
      __fpga_str_cat_str(str, ":")
      __fpga_str_cat_str(str, __fpga_ptr_to_str(__fpga_addr(obj)))
    end
    __fpga_str_cat_str(str, ">")
  end

  # iv の表を行の順に辿る (mruby は symbol の番号の順に並べた表。順は D06 / D07)
  # C: src/kernel.c inspect_i (D06)
  def __fpga_inspect_ivs(ci, obj)
    t = __fpga_ld32(__fpga_addr(obj) + 60) # L:IV
    return nil if t == 0 || __fpga_ld32(t + 0) == 0 # L:MT_COUNT
    str = "#<" # C は "-<" で始めて最初の iv で '#' に書き換える
    __fpga_str_cat_str(str, __fpga_mod_to_s(__fpga_obj_class(obj)))
    __fpga_str_cat_str(str, ":")
    __fpga_str_cat_str(str, __fpga_ptr_to_str(__fpga_addr(obj)))
    if __fpga_recursive_method_p(ci, __fpga_addr(:inspect), obj, nil) # MRB_RECURSIVE_UNARY_P
      __fpga_st8(__fpga_ld32(__fpga_addr(str) + 16), 45) # L:S_PTR '-' のまま
      __fpga_str_cat_str(str, " ...>")
      return str
    end
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    rows = __fpga_ld32(t + 8) # L:MT_ROWS
    first = true
    k = 0
    while k < capa
      sym = __fpga_ld32(rows + k * 20) # L:IV_ENTRY
      if sym < 4294967295 # L:MT_EMPTY
        __fpga_str_cat_str(str, first ? " " : ", ")
        first = false
        __fpga_str_cat_str(str, __fpga_sym_str(sym))
        __fpga_str_cat_str(str, "=")
        __fpga_str_cat_str(str, __fpga_inspect(__fpga_ldv(rows + k * 20 + 4))) # L:IV_ENTRY
      end
      k += 1
    end
    __fpga_str_cat_str(str, ">")
  end

  # iv の表を写す (dest の表を新しく作る)
  # C: src/variable.c mrb_iv_copy (D06)
  def __fpga_iv_copy(dest, obj)
    t = __fpga_ld32(__fpga_addr(obj) + 60) # L:IV
    __fpga_st32(__fpga_addr(dest) + 60, 0) # L:IV
    return if t == 0
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    rows = __fpga_ld32(t + 8) # L:MT_ROWS
    k = 0
    while k < capa
      sym = __fpga_ld32(rows + k * 20) # L:IV_ENTRY
      __fpga_tbl_set(__fpga_iv_tbl(__fpga_addr(dest)), sym, __fpga_ldv(rows + k * 20 + 4)) if sym < 4294967295 # L:MT_EMPTY
      k += 1
    end
  end

  # dup の中身: iv を持つ型は iv を写し、initialize_copy が Kernel のもの (mrb_obj_init_copy) でなければ送る
  # C: src/class.c init_copy
  def __fpga_init_copy(dest, obj)
    t = __fpga_tt(__fpga_addr(obj))
    if t == 15 # L:TT_ICLASS
      __fpga_copy_class(dest, obj)
      return
    end
    if t == 9 || t == 10 # L:TT_CLASS L:TT_MODULE
      __fpga_copy_class(dest, obj)
      __fpga_iv_copy(dest, obj) # 名前 (__classname__) は C_NAME の欄なので写さない (D04)
      __fpga_st32(__fpga_addr(dest) + 24, 0) # L:C_NAME
      __fpga_st32(__fpga_addr(dest) + 28, 0) # L:C_OUTER
    end
    __fpga_iv_copy(dest, obj) if t == 8 || t == 11 || t == 12 || t == 13 || t == 14 # L:TT_OBJECT L:TT_SCLASS L:TT_HASH L:TT_CDATA L:TT_EXCEPTION
    return if __fpga_func_basic_p(dest, __fpga_addr(:initialize_copy), Kernel)
    __fpga_sendv(dest, :initialize_copy, [obj], nil, true) # mrb_funcall_argv (private の initialize_copy も呼ぶ)
  end

  # MakeID: 番地 (即値は値) と tt の xor
  # C: src/etc.c mrb_obj_id
  def __fpga_obj_id(obj)
    t = __fpga_tag(obj)
    return __fpga_xor(4, 0) if t == 0 # L:TAG_NIL MakeID(4, MRB_TT_FALSE)
    return __fpga_xor(0, 0) if t == 1 # L:TAG_FALSE MakeID(0, MRB_TT_FALSE)
    return __fpga_xor(2, 1) if t == 2 # L:TAG_TRUE MakeID(2, MRB_TT_TRUE)
    return __fpga_xor(__fpga_addr(obj), 2) if t == 4 # L:TAG_SYM MRB_TT_SYMBOL
    return __fpga_xor(obj, 6) if t == 3 # L:TAG_INT MRB_TT_INTEGER
    return __fpga_xor(__fpga_float_id(__fpga_int(obj)), 5) if t == 5 # L:TAG_FLOAT MakeID(mrb_float_id(f), MRB_TT_FLOAT)
    __fpga_xor(__fpga_addr(obj), __fpga_tt(__fpga_addr(obj)))
  end

  # 即値はそのまま。特異クラスがあればそれも凍らせる
  # C: src/kernel.c mrb_obj_freeze
  def __fpga_obj_freeze(obj)
    return obj unless __fpga_tag(obj) == 7 # L:TAG_OBJ mrb_immediate_p
    b = __fpga_addr(obj)
    unless __fpga_frozen_p(b)
      __fpga_st32(b + 4, __fpga_or(__fpga_ld32(b + 4), 2048)) # L:H_FLAGS L:H_FROZEN
      c = __fpga_ld32(b + 0) # L:H_CLASS
      __fpga_st32(c + 4, __fpga_or(__fpga_ld32(c + 4), 2048)) if __fpga_tt(c) == 11 # L:H_FLAGS L:H_FROZEN L:TT_SCLASS
    end
    obj
  end

  # C: include/mruby/object.h mrb_frozen_p
  def __fpga_frozen_p(o)
    __fpga_and(__fpga_ld32(o + 4), 2048) > 0 # L:H_FLAGS L:H_FROZEN
  end

  # C: src/error.c mrb_check_frozen
  def __fpga_check_frozen(o)
    __fpga_raisef(FrozenError, "can't modify frozen %T", [__fpga_obj(o)]) if __fpga_frozen_p(o) # frozen_error
  end

  # 呼び出しの鎖 (ci) に、同じメソッドが同じ受け手 (と引数) で積まれているか。ci は C の関数の ci (firmware の def のフレーム)。
  # method_p は ci[-1] から、func_p は ci[-2] から cibase まで
  # C: src/kernel.c mrb_recursive_method_p
  def __fpga_recursive_method_p(ci, mid, obj1, obj2)
    base = __fpga_ld32(__fpga_image(0) + 16) # L:IMG_c L:CTX_CIBASE
    c = ci - 64 # L:CI_SIZE
    while c >= base
      if __fpga_ld32(c + 4) == mid # L:CI_MID
        st = __fpga_ld32(c + 16) # L:CI_STACK
        s0 = __fpga_ldv(st)
        if __fpga_tag(obj1) == __fpga_tag(s0) && __fpga_int(obj1) == __fpga_int(s0) # mrb_obj_eq
          return true if __fpga_tag(obj2) == 0 # L:TAG_NIL
          s1 = __fpga_ldv(st + 16) # L:VALUE
          return true if __fpga_tag(obj2) == __fpga_tag(s1) && __fpga_int(obj2) == __fpga_int(s1)
        end
      end
      c -= 64 # L:CI_SIZE
    end
    false
  end

  # C: src/kernel.c mrb_recursive_func_p
  def __fpga_recursive_func_p(ci, mid, obj1, obj2)
    base = __fpga_ld32(__fpga_image(0) + 16) # L:IMG_c L:CTX_CIBASE
    c = ci - 128 # ci[-2] (CI_SIZE の 2 つ)
    while c >= base
      if __fpga_ld32(c + 4) == mid # L:CI_MID
        st = __fpga_ld32(c + 16) # L:CI_STACK
        s0 = __fpga_ldv(st)
        if __fpga_tag(obj1) == __fpga_tag(s0) && __fpga_int(obj1) == __fpga_int(s0) # mrb_obj_eq
          return true if __fpga_tag(obj2) == 0 # L:TAG_NIL
          s1 = __fpga_ldv(st + 16) # L:VALUE
          return true if __fpga_tag(obj2) == __fpga_tag(s1) && __fpga_int(obj2) == __fpga_int(s1)
        end
      end
      c -= 64 # L:CI_SIZE
    end
    false
  end

  # 同じものか、Integer / Float / String は型と値、ほかは eql? (Kernel#eql? のままなら偽)
  # C: src/object.c mrb_eql
  def __fpga_eql(obj1, obj2)
    return true if __fpga_tag(obj1) == __fpga_tag(obj2) && __fpga_int(obj1) == __fpga_int(obj2) # mrb_obj_eq
    t = __fpga_tag(obj1)
    if t == 3 # L:TAG_INT
      return false unless __fpga_tag(obj2) == 3 # L:TAG_INT
      return __fpga_int(obj1) == __fpga_int(obj2)
    elsif t == 5 # L:TAG_FLOAT
      return false unless __fpga_tag(obj2) == 5 # L:TAG_FLOAT
      return __fpga_float_eq(obj1, obj2)
    elsif t == 7 && __fpga_tt(__fpga_addr(obj1)) == 18 # L:TAG_OBJ L:TT_STRING
      return false unless __fpga_tag(obj2) == 7 && __fpga_tt(__fpga_addr(obj2)) == 18 # L:TAG_OBJ L:TT_STRING
      return __fpga_str_equal(obj1, obj2)
    end
    return false if __fpga_func_basic_p(obj1, __fpga_addr(:eql?), Kernel) # mrb_obj_equal_m
    obj1.eql?(obj2) ? true : false
  end

  # double の == (soft-float の __eqdf2): ビットが同じ (NaN を除く) か、両方とも ±0
  # C: none (D17)
  def __fpga_float_eq(a, b)
    x = __fpga_int(a)
    y = __fpga_int(b)
    nan_x = __fpga_and(x, 9218868437227405312) == 9218868437227405312 && __fpga_and(x, 4503599627370495) > 0 # 指数が全部 1 で仮数が 0 でない
    return false if nan_x
    return true if x == y
    __fpga_and(x, 9223372036854775807) == 0 && __fpga_and(y, 9223372036854775807) == 0
  end

  # C の中で == が決まるか: 1 真、0 偽、-1 は == が Ruby (VM で送る)
  # C: src/object.c mrb_equal_in_c
  def __fpga_equal_in_c(obj1, obj2)
    return 1 if __fpga_tag(obj1) == __fpga_tag(obj2) && __fpga_int(obj1) == __fpga_int(obj2) # mrb_obj_eq
    t1 = __fpga_tag(obj1)
    t2 = __fpga_tag(obj2)
    return 0 if t1 == 3 && t2 == 3 && __fpga_and(__fpga_image(45), 16) == 0 # L:TAG_INT L:IMG_bop_redefined MRB_BOP_INTEGER(MRB_BOP_EQ)
    return __fpga_int_float_cmp(obj1, __fpga_int(obj2)) == 0 ? 1 : 0 if t1 == 3 && t2 == 5 # L:TAG_INT L:TAG_FLOAT
    return __fpga_int_float_cmp(obj2, __fpga_int(obj1)) == 0 ? 1 : 0 if t1 == 5 && t2 == 3 # L:TAG_FLOAT L:TAG_INT
    return 0 if t1 == 4 && t2 == 4 && __fpga_and(__fpga_image(45), 262144) == 0 # L:TAG_SYM L:IMG_bop_redefined MRB_BOP_SYMBOL_EQ
    m = __fpga_and(__fpga_search(__fpga_addr(__fpga_class_of(obj1)), __fpga_addr(:==)), -4) # L:VIS_MASK (~3)
    return -1 if m == 0 || m >= __fpga_image(35) # L:IMG_heap_start 像の外の Proc は Ruby のメソッド (MRB_METHOD_CFUNC_P でない)
    return 0 if m == __fpga_and(__fpga_search(__fpga_addr(BasicObject), __fpga_addr(:==)), -4) # L:VIS_MASK (~3) mrb_obj_equal_m
    __fpga_sendv(obj1, :==, [obj2], nil, true) ? 1 : 0 # mrb_funcall_argv
  end
end

module Kernel
  # C: src/object.c mrb_any_to_s
  def to_s
    __fpga_any_to_s(self)
  end

  # iv のある普通のオブジェクトで to_s が Kernel のものなら "#<C:0x.. @a=1>"、ほかは to_s と同じ形
  # C: src/kernel.c mrb_obj_inspect
  def inspect
    if __fpga_tag(self) == 7 && __fpga_tt(__fpga_addr(self)) == 8 && __fpga_func_basic_p(self, __fpga_addr(:to_s), Kernel) # L:TAG_OBJ L:TT_OBJECT
      s = __fpga_inspect_ivs(__fpga_ld32(__fpga_image(0) + 12), self) # L:IMG_c L:CTX_CI mrb->c->ci
      return s unless __fpga_tag(s) == 0 # L:TAG_NIL
    end
    __fpga_any_to_s(self)
  end

  # C: src/class.c mrb_obj_dup
  def dup
    return self unless __fpga_tag(self) == 7 # L:TAG_OBJ mrb_immediate_p
    __fpga_raise(TypeError, "can't dup singleton class") if __fpga_tt(__fpga_addr(self)) == 11 # L:TT_SCLASS
    d = __fpga_obj(__fpga_slot(__fpga_addr(__fpga_obj_class(self)), __fpga_tt(__fpga_addr(self))))
    __fpga_init_copy(d, self)
    d
  end

  # === は == (NaN の Float は偽)
  # C: src/kernel.c mrb_eqq_m
  def ===(arg)
    if __fpga_tag(self) == 5 # L:TAG_FLOAT
      x = __fpga_int(self)
      return false if __fpga_and(x, 9218868437227405312) == 9218868437227405312 && __fpga_and(x, 4503599627370495) > 0 # isnan
    end
    __fpga_equal(self, arg)
  end

  # rescue *list と when *list の中身: 自分 (配列か to_a) の要素のどれかが v と === か
  # C: src/kernel.c mrb_obj_ceqq
  def __case_eqq(v)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, 0) # L:CI_MID mrb->c->ci->mid = 0
    if __fpga_tag(self) == 7 && __fpga_tt(__fpga_addr(self)) == 17 # L:TAG_OBJ L:TT_ARRAY
      ary = self
    elsif __fpga_tag(self) == 0 # L:TAG_NIL
      return false
    elsif __fpga_search(__fpga_addr(__fpga_class_of(self)), __fpga_addr(:to_a)) == 0 # mrb_respond_to
      return (self === v) ? true : false
    else
      ary = to_a
      return self === v if __fpga_tag(ary) == 0 # L:TAG_NIL
      __fpga_ensure_array_type(ary)
    end
    len = __fpga_alen(ary)
    i = 0
    while i < len && i < __fpga_alen(ary)
      return true if __fpga_aref(ary, i) === v
      i += 1
    end
    false
  end

  # C: src/kernel.c mrb_obj_hash
  def hash
    __fpga_obj_id(self)
  end

  # C: src/kernel.c mrb_obj_equal_m
  def eql?(obj)
    __fpga_tag(self) == __fpga_tag(obj) && __fpga_int(self) == __fpga_int(obj) # mrb_obj_equal
  end

  # C: src/kernel.c mrb_obj_freeze
  def freeze
    __fpga_obj_freeze(self)
  end

  # C: src/kernel.c mrb_obj_frozen
  def frozen?
    __fpga_tag(self) == 7 ? __fpga_frozen_p(__fpga_addr(self)) : true # L:TAG_OBJ mrb_immediate_p
  end

  # C: src/kernel.c mrb_obj_init_copy
  def initialize_copy(orig)
    return self if __fpga_tag(orig) == __fpga_tag(self) && __fpga_int(orig) == __fpga_int(self) # mrb_obj_equal
    same = __fpga_tag(orig) == __fpga_tag(self) && __fpga_addr(__fpga_obj_class(orig)) == __fpga_addr(__fpga_obj_class(self))
    same = __fpga_tt(__fpga_addr(orig)) == __fpga_tt(__fpga_addr(self)) if same && __fpga_tag(self) == 7 # L:TAG_OBJ mrb_type
    __fpga_raise(TypeError, "initialize_copy should take same class object") unless same
    self
  end
end

class BasicObject
  # C: src/class.c mrb_obj_id_m
  def __id__
    __fpga_obj_id(self)
  end
end

class NilClass
  # C: mrbgems/mruby-object-ext/src/object.c nil_to_a
  def to_a
    []
  end

  # C: src/object.c nil_to_s
  def to_s
    ""
  end

  # C: src/object.c nil_inspect
  def inspect
    "nil"
  end

  # C: src/object.c mrb_true
  def nil?
    true
  end

  # C: src/object.c false_or
  def |(obj2)
    obj2 ? true : false
  end
end

class TrueClass
  # C: src/object.c true_to_s
  def to_s
    "true"
  end

  alias inspect to_s # object.c は to_s と inspect に同じ関数 true_to_s を置く

  # C: src/object.c true_or
  def |(obj2)
    true
  end
end

class FalseClass
  # C: src/object.c false_to_s
  def to_s
    "false"
  end

  alias inspect to_s # object.c は to_s と inspect に同じ関数 false_to_s を置く

  # C: src/object.c false_or
  def |(obj2)
    obj2 ? true : false
  end
end

class Module
  # C: src/class.c mrb_mod_to_s
  def inspect
    __fpga_mod_to_s(self)
  end

  # C: src/class.c mrb_mod_eqq
  def ===(obj)
    __fpga_kind_of(obj, self)
  end

  # C: src/class.c mrb_mod_include_p
  def include?(mod2)
    __fpga_raisef(TypeError, "%v is not class/module", [mod2]) unless __fpga_tag(mod2) == 7 && __fpga_class_p(__fpga_addr(mod2)) # L:TAG_OBJ mrb_get_args の C (ensure_class_type)
    __fpga_raisef(TypeError, "wrong argument type %v (expected Module)", [__fpga_obj_class(mod2)]) unless __fpga_tt(__fpga_addr(mod2)) == 10 # L:TT_MODULE mrb_check_type
    c = __fpga_addr(self)
    m = __fpga_addr(mod2)
    while c > 0
      return true if __fpga_tt(c) == 15 && __fpga_ld32(c + 0) == m # L:TT_ICLASS L:H_CLASS iclass の c は module
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    false
  end
end
