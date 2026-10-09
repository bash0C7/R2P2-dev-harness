# firmware: Array の C の所 (mruby の src/array.c と mruby-array-ext)。配列の部分 (ary_subseq) は共有せずに写す
# (mruby は長い部分を共有して書く時に写すが、見える意味は同じ)。
# 引数の形は C の MRB_MT_ENTRY の aspec と同じにする (REQ は決まった数の引数、OPT と ARG は *args と check_argument_count の写し)
class Array
  # C: src/array.c mrb_ary_size
  def size
    __fpga_ld32(__fpga_addr(self) + 8) # L:A_LEN
  end

  alias length size # array.c は size と length に同じ関数 mrb_ary_size を置く

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
    __fpga_check_frozen(a) # ary_modify
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_ary_expand_capa(a, len + 1) if len >= __fpga_ld32(a + 12) # L:A_CAPA
    __fpga_stv(__fpga_ld32(a + 16) + len * 16, v) # L:A_PTR L:VALUE
    __fpga_st32(a + 8, len + 1) # L:A_LEN
  end

  # C: src/array.c mrb_ary_empty_p
  def empty?
    __fpga_alen(self) == 0
  end

  # [] / slice: 整数、Range、(添字, 長さ)
  # C: src/array.c mrb_ary_aget
  def [](*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    alen = __fpga_alen(self)
    index = __fpga_aref(args, 0)
    if __fpga_alen(args) == 1
      if __fpga_tag(index) == 7 && __fpga_tt(__fpga_addr(index)) == 19 # L:TAG_OBJ L:TT_RANGE
        bl = __fpga_range_beg_len(index, alen, true)
        return nil unless bl
        return __fpga_ary_subseq(self, __fpga_aref(bl, 0), __fpga_aref(bl, 1))
      end
      return __fpga_ary_ref(self, __fpga_ary_index(index))
    end
    __fpga_raise_argnum(__fpga_alen(args), 2, 2) unless __fpga_alen(args) == 2 # mrb_get_args の oi
    i = __fpga_ary_index(index)
    len = __fpga_as_int(__fpga_aref(args, 1))
    i += alen if i < 0
    return nil if i < 0 || alen < i
    return nil if len < 0
    return [] if alen == i
    len = alen - i if len > alen - i
    __fpga_ary_subseq(self, i, len)
  end

  alias slice [] # array.c は [] と slice に同じ関数 mrb_ary_aget を置く

  # []= : 整数か Range と値、(添字, 長さ, 値)
  # C: src/array.c mrb_ary_aset
  def []=(*args)
    __fpga_check_argc(args, 2, 3) # MRB_ARGS_ARG(2,1)
    if __fpga_alen(args) == 2
      v1 = __fpga_aref(args, 0)
      v2 = __fpga_aref(args, 1)
      bl = __fpga_range_beg_len(v1, __fpga_alen(self), false)
      if bl == nil # MRB_RANGE_TYPE_MISMATCH
        __fpga_ary_set(self, __fpga_ary_index(v1), v2)
      elsif bl == false # MRB_RANGE_OUT
        __fpga_raisef(RangeError, "%v out of range", [v1])
      else
        __fpga_ary_splice(self, __fpga_aref(bl, 0), __fpga_aref(bl, 1), v2)
      end
      return v2
    end
    __fpga_raise_argnum(__fpga_alen(args), 3, 3) unless __fpga_alen(args) == 3 # mrb_get_args の ooo
    v3 = __fpga_aref(args, 2)
    __fpga_ary_splice(self, __fpga_ary_index(__fpga_aref(args, 0)), __fpga_ary_index(__fpga_aref(args, 1)), v3)
    v3
  end

  # C: src/array.c mrb_ary_plus
  def +(other)
    other = __fpga_ensure_array_type(other) # mrb_get_args の a
    r = __fpga_ary_subseq(self, 0, __fpga_alen(self))
    __fpga_ary_concat(r, other)
    r
  end

  # C: src/array.c mrb_ary_eq
  def ==(ary2)
    return true if __fpga_tag(ary2) == 7 && __fpga_addr(ary2) == __fpga_addr(self) # L:TAG_OBJ ary_eq の mrb_obj_equal
    return false unless __fpga_tag(ary2) == 7 && __fpga_tt(__fpga_addr(ary2)) == 17 # L:TAG_OBJ L:TT_ARRAY
    return false unless __fpga_alen(self) == __fpga_alen(ary2)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    return true if __fpga_recursive_func_p(ci, __fpga_addr(:==), self, ary2) # MRB_RECURSIVE_BINARY_FUNC_P
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(self)
      a = __fpga_ary_ref(self, i) # mrb_ary_entry
      b = __fpga_ary_ref(ary2, i)
      unless __fpga_tag(a) == __fpga_tag(b) && __fpga_int(a) == __fpga_int(b) # mrb_obj_eq
        return false unless __fpga_sendv(a, :==, [b], nil, true) # mrb_funcall_argv1
      end
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    true
  end

  # C: src/array.c mrb_ary_init
  def initialize(*args, &blk)
    __fpga_check_argc(args, 0, 2) # mrb_get_args の |oo&
    ss = __fpga_alen(args) > 0 ? __fpga_aref(args, 0) : 0
    obj = __fpga_alen(args) > 1 ? __fpga_aref(args, 1) : nil
    if __fpga_tag(ss) == 7 && __fpga_tt(__fpga_addr(ss)) == 17 && __fpga_tag(obj) == 0 && __fpga_tag(blk) == 0 # L:TAG_OBJ L:TT_ARRAY L:TAG_NIL
      __fpga_ary_replace(self, ss)
      return self
    end
    size = __fpga_as_int(ss)
    __fpga_check_frozen(__fpga_addr(self)) # ary_modify_check
    ai = __fpga_gc_arena_save
    i = 0
    while i < size
      __fpga_ary_set(self, i, __fpga_tag(blk) == 0 ? obj : yield(i)) # L:TAG_NIL mrb_yield
      __fpga_gc_arena_restore(ai) # for mrb_funcall
      i += 1
    end
    self
  end

  # C: src/array.c mrb_ary_unshift_m
  def unshift(*items)
    __fpga_check_frozen(__fpga_addr(self)) # mrb_ary_unshift_values の ary_modify
    k = __fpga_alen(items)
    while k > 0
      k -= 1
      __fpga_ary_unshift1(self, __fpga_aref(items, k))
    end
    self
  end

  # C: src/array.c mrb_ary_replace_m
  def replace(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    __fpga_ary_replace_v(self, other)
    self
  end

  alias initialize_copy replace # array.c は replace と initialize_copy に同じ関数 mrb_ary_replace_m を置く

  # C: src/array.c mrb_ary_s_create
  def self.[](*vals)
    ary = __fpga_ary_subseq(vals, 0, __fpga_alen(vals))
    __fpga_st32(__fpga_addr(ary) + 0, __fpga_addr(self)) # L:H_CLASS a->c = klass
    ary
  end

  # C: src/array.c mrb_ary_concat_m
  def concat(other)
    args = [other] # MRB_ARGS_REQ(1) で数を見てから mrb_get_args の *!
    i = 0
    while i < __fpga_alen(args)
      __fpga_ensure_array_type(__fpga_aref(args, i))
      i += 1
    end
    i = 0
    while i < __fpga_alen(args)
      __fpga_ary_concat(self, __fpga_aref(args, i))
      i += 1
    end
    self
  end

  # C: src/array.c mrb_ary_index_m
  def index(*args, &blk)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    return to_enum(:index) if __fpga_alen(args) == 0 && __fpga_tag(blk) == 0 # L:TAG_NIL
    i = 0
    if __fpga_tag(blk) == 0 # L:TAG_NIL
      obj = __fpga_aref(args, 0)
      while i < __fpga_alen(self)
        return i if __fpga_equal(__fpga_aref(self, i), obj)
        i += 1
      end
    else
      while i < __fpga_alen(self)
        return i if yield(__fpga_aref(self, i))
        i += 1
      end
    end
    nil
  end

  # C: src/array.c mrb_ary_last
  def last(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    alen = __fpga_alen(self)
    if __fpga_alen(args) == 0
      return alen > 0 ? __fpga_aref(self, alen - 1) : nil
    end
    size = __fpga_as_int(__fpga_aref(args, 0))
    __fpga_raise(ArgumentError, "negative array size") if size < 0
    size = alen if size > alen
    __fpga_ary_subseq(self, alen - size, size)
  end

  # C: src/array.c mrb_ary_pop
  def pop
    __fpga_ary_pop(self)
  end

  # C: src/array.c mrb_ary_clear
  def clear
    __fpga_check_frozen(__fpga_addr(self)) # ary_modify の ary_modify_check
    __fpga_st32(__fpga_addr(self) + 8, 0) # L:A_LEN
    self
  end

  # C: src/array.c mrb_ary_to_s
  def to_s
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, __fpga_addr(:inspect)) # L:CI_MID mrb->c->ci->mid = MRB_SYM(inspect)
    ret = "["
    ai = __fpga_gc_arena_save
    if __fpga_recursive_method_p(ci, __fpga_addr(:inspect), self, nil) # MRB_RECURSIVE_UNARY_P
      __fpga_str_cat_str(ret, "...]")
      return ret
    end
    i = 0
    while i < __fpga_alen(self)
      __fpga_str_cat_str(ret, ", ") if i > 0
      __fpga_str_cat_str(ret, __fpga_inspect(__fpga_aref(self, i)))
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    __fpga_str_cat_str(ret, "]")
  end

  alias inspect to_s # array.c は to_s と inspect に同じ関数 mrb_ary_to_s を置く

  # C: src/array.c mrb_ary_join_m
  def join(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    sep = __fpga_alen(args) > 0 ? __fpga_aref(args, 0) : nil
    sep = __fpga_ensure_string_type(sep) unless __fpga_tag(sep) == 0 # L:TAG_NIL mrb_get_args の S!
    __fpga_join_ary(self, sep)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_include
  def include?(obj)
    i = 0
    while i < __fpga_alen(self)
      return true if __fpga_equal(__fpga_aref(self, i), obj)
      i += 1
    end
    false
  end

  alias member? include? # mruby-array-ext は include? と member? に同じ関数 ary_include を置く

  # C: src/array.c mrb_ary_eql
  def eql?(ary2)
    return true if __fpga_tag(ary2) == 7 && __fpga_addr(ary2) == __fpga_addr(self) # L:TAG_OBJ ary_eq の mrb_obj_equal
    return false unless __fpga_tag(ary2) == 7 && __fpga_tt(__fpga_addr(ary2)) == 17 # L:TAG_OBJ L:TT_ARRAY
    return false unless __fpga_alen(self) == __fpga_alen(ary2)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    return true if __fpga_recursive_func_p(ci, __fpga_addr(:eql?), self, ary2)
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(self)
      return false unless __fpga_ary_ref(self, i).eql?(__fpga_ary_ref(ary2, i)) # mrb_ary_entry
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    true
  end

  # 0 個は nil、1 個はその要素、ほかは自分 (enum.rb の |*val| の値)
  # C: src/array.c mrb_ary_svalue
  def __svalue
    len = __fpga_alen(self)
    return nil if len == 0
    return __fpga_aref(self, 0) if len == 1
    self
  end

  # __svalue の値と other が == か (mrb_equal_in_c)。== が Ruby なら :send (呼んだ mrblib が送る)
  # C: src/array.c mrb_ary_svalue_eq
  def __svalue_eq(other)
    len = __fpga_alen(self)
    v = len == 0 ? nil : (len == 1 ? __fpga_aref(self, 0) : self) # mrb_ary_svalue
    r = __fpga_equal_in_c(v, other)
    return :send if r < 0
    r == 1
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_sub
  def -(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    __fpga_ary_subtract_internal(self, [other])
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_union
  def |(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    __fpga_ary_union_internal(self, [other])
  end

  # C: src/array.c mrb_ary_times
  def *(arg)
    if __fpga_tag(arg) == 7 && __fpga_tt(__fpga_addr(arg)) == 18 # L:TAG_OBJ L:TT_STRING mrb_check_string_type
      return __fpga_join_ary(self, arg) # mrb_ary_join
    end
    times = __fpga_as_int(arg)
    __fpga_raise(ArgumentError, "negative argument") if times < 0
    return [] if times == 0
    len1 = __fpga_alen(self)
    __fpga_raise(ArgumentError, "array size too big") if 268435455 / times < len1 # ARY_MAX_SIZE (32bit の SIZE_MAX / sizeof(mrb_value)) ary_too_big
    a2 = []
    a = __fpga_addr(a2)
    __fpga_ary_expand_capa(a, len1 * times) if len1 * times > 0 # ary_new_capa
    __fpga_st32(a + 8, len1 * times) # L:A_LEN
    ptr = __fpga_ld32(a + 16) # L:A_PTR
    src = __fpga_ld32(__fpga_addr(self) + 16) # L:A_PTR
    while times > 0 && len1 > 0
      __fpga_copy(ptr, src, len1 * 16) # L:VALUE array_copy
      ptr += len1 * 16 # L:VALUE
      times -= 1
    end
    a2
  end

  # C: src/array.c mrb_ary_reverse_bang
  def reverse!
    a = __fpga_addr(self)
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # len > 1 は ary_modify、ほかは ary_modify_check
    if len > 1
      p1 = __fpga_ld32(a + 16) # L:A_PTR
      p2 = p1 + (len - 1) * 16 # L:VALUE
      while p1 < p2
        tmp = __fpga_ldv(p1)
        __fpga_stv(p1, __fpga_ldv(p2))
        __fpga_stv(p2, tmp)
        p1 += 16 # L:VALUE
        p2 -= 16 # L:VALUE
      end
    end
    self
  end

  # C: src/array.c mrb_ary_reverse
  def reverse
    len = __fpga_alen(self)
    b = []
    if len > 0
      ba = __fpga_addr(b)
      __fpga_ary_expand_capa(ba, len) # ary_new_capa
      p1 = __fpga_ld32(__fpga_addr(self) + 16) # L:A_PTR
      e = p1 + len * 16 # L:VALUE
      p2 = __fpga_ld32(ba + 16) + (len - 1) * 16 # L:A_PTR L:VALUE
      while p1 < e
        __fpga_stv(p2, __fpga_ldv(p1))
        p2 -= 16 # L:VALUE
        p1 += 16 # L:VALUE
      end
      __fpga_st32(ba + 8, len) # L:A_LEN
    end
    b
  end

  # 引数が無ければ先頭の 1 つ、あれば先頭の n 個を抜く。残りは前へ詰める (ary_make_shared を写さない、D63)
  # C: src/array.c mrb_ary_shift_m
  def shift(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    return __fpga_ary_shift(self) if __fpga_alen(args) == 0
    n = __fpga_as_int(__fpga_aref(args, 0))
    a = __fpga_addr(self)
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # ary_modify_check
    return [] if len == 0 || n == 0
    __fpga_raise(ArgumentError, "negative array shift") if n < 0
    n = len if n > len
    val = __fpga_ary_subseq(self, 0, n) # mrb_ary_new_from_values
    if len == n
      __fpga_st32(a + 8, 0) # L:A_LEN
    else
      ptr = __fpga_ld32(a + 16) # L:A_PTR
      size = len - n
      while size > 0
        __fpga_stv(ptr, __fpga_ldv(ptr + n * 16)) # L:VALUE
        ptr += 16 # L:VALUE
        size -= 1
      end
      __fpga_st32(a + 8, len - n) # L:A_LEN
    end
    val
  end

  # C: src/array.c mrb_ary_delete_at
  def delete_at(index)
    __fpga_ary_delete_at(self, index)
  end

  # C: src/array.c mrb_ary_first
  def first(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    alen = __fpga_alen(self)
    if __fpga_alen(args) == 0
      return alen > 0 ? __fpga_aref(self, 0) : nil
    end
    size = __fpga_as_int(__fpga_aref(args, 0)) # mrb_get_args の |i
    __fpga_raise(ArgumentError, "negative array size") if size < 0
    size = alen if size > alen
    __fpga_ary_subseq(self, 0, size)
  end

  # C: src/array.c mrb_ary_rindex_m
  def rindex(*args, &blk)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    return to_enum(:rindex) if __fpga_alen(args) == 0 && __fpga_tag(blk) == 0 # L:TAG_NIL
    obj = __fpga_alen(args) > 0 ? __fpga_aref(args, 0) : nil
    i = __fpga_alen(self) - 1
    while i >= 0
      if __fpga_tag(blk) == 0 # L:TAG_NIL
        return i if __fpga_equal(__fpga_aref(self, i), obj)
      elsif yield(__fpga_aref(self, i)) # mrb_yield
        return i
      end
      len = __fpga_alen(self)
      i = len if i > len
      i -= 1
    end
    nil
  end

  # C: src/array.c mrb_ary_cmp
  def <=>(ary2)
    return 0 if __fpga_tag(ary2) == __fpga_tag(self) && __fpga_int(ary2) == __fpga_int(self) # mrb_obj_equal
    return nil unless __fpga_tag(ary2) == 7 && __fpga_tt(__fpga_addr(ary2)) == 17 # L:TAG_OBJ L:TT_ARRAY
    i = 0
    while i < __fpga_alen(self) && i < __fpga_alen(ary2)
      n = __fpga_cmp(__fpga_aref(self, i), __fpga_aref(ary2, i))
      return nil if n == -2
      return n unless n == 0
      i += 1
    end
    len = __fpga_alen(self) - __fpga_alen(ary2)
    return 0 if len == 0
    len > 0 ? 1 : -1
  end

  # C: src/array.c mrb_ary_delete
  def delete(obj, &blk)
    ret = obj
    ai = __fpga_gc_arena_save
    i = 0
    j = 0
    while i < __fpga_alen(self)
      elem = __fpga_aref(self, i)
      if __fpga_equal(elem, obj)
        __fpga_gc_arena_restore(ai)
        __fpga_gc_protect_value(elem)
        ret = elem
        i += 1
        next
      end
      unless i == j
        __fpga_raise(RuntimeError, "array modified during delete") if j >= __fpga_alen(self)
        __fpga_check_frozen(__fpga_addr(self)) # ary_modify
        __fpga_stv(__fpga_ld32(__fpga_addr(self) + 16) + j * 16, elem) # L:A_PTR L:VALUE
      end
      j += 1
      i += 1
    end
    if i == j
      return nil if __fpga_tag(blk) == 0 # L:TAG_NIL
      return yield(obj) # mrb_yield
    end
    __fpga_st32(__fpga_addr(self) + 8, j) # L:A_LEN
    ret
  end

  # C: src/array.c mrb_ary_to_a
  def to_a
    return self if __fpga_addr(__fpga_obj_class(self)) == __fpga_addr(Array)
    __fpga_ary_subseq(self, 0, __fpga_alen(self)) # mrb_ary_dup
  end

  alias entries to_a # array.c は to_a と entries に同じ関数 mrb_ary_to_a を置く

  # 要素が全部 Integer か全部 (Array の子でない) String なら <=> を送らずに比べる。16 個までは挿入ソート、それより多ければヒープソート
  # C: src/array.c mrb_ary_sort_bang
  def sort!(&blk)
    a = __fpga_addr(self)
    n = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # n < 2 は ary_modify_check、ほかは ary_modify
    return self if n < 2
    p = __fpga_ld32(a + 16) # L:A_PTR
    if __fpga_tag(blk) == 0 && __fpga_ary_all_fixnum_p(p, n) # L:TAG_NIL
      if n <= 16 # SMALL_ARRAY_SORT_THRESHOLD
        __fpga_insertion_sort_fixnum(p, n)
      else
        i = n / 2 - 1
        while i >= 0
          __fpga_heapify_fixnum(p, i, n)
          i -= 1
        end
        i = n - 1
        while i > 0
          tmp = __fpga_ldv(p)
          __fpga_stv(p, __fpga_ldv(p + i * 16)) # L:VALUE
          __fpga_stv(p + i * 16, tmp) # L:VALUE
          __fpga_heap_delete_root_fixnum(p, i)
          i -= 1
        end
      end
      return self
    end
    if __fpga_tag(blk) == 0 && __fpga_ary_all_string_p(p, n) # L:TAG_NIL
      if n <= 16 # SMALL_ARRAY_SORT_THRESHOLD
        __fpga_insertion_sort_str(p, n)
      else
        i = n / 2 - 1
        while i >= 0
          __fpga_heapify_str(p, i, n)
          i -= 1
        end
        i = n - 1
        while i > 0
          tmp = __fpga_ldv(p)
          __fpga_stv(p, __fpga_ldv(p + i * 16)) # L:VALUE
          __fpga_stv(p + i * 16, tmp) # L:VALUE
          __fpga_heap_delete_root_str(p, i)
          i -= 1
        end
      end
      return self
    end
    if n <= 16 # SMALL_ARRAY_SORT_THRESHOLD
      __fpga_insertion_sort(self, p, n, &blk)
    else
      i = n / 2 - 1
      while i >= 0
        __fpga_heapify(self, p, i, n, &blk)
        i -= 1
      end
      i = n - 1
      while i > 0
        max = __fpga_ldv(p)
        __fpga_stv(p, __fpga_ldv(p + i * 16)) # L:VALUE
        __fpga_stv(p + i * 16, max) # L:VALUE
        __fpga_heap_delete_root(self, p, i, &blk)
        i -= 1
      end
    end
    self
  end

  # --- mruby-array-ext の C
  # C: mrbgems/mruby-array-ext/src/array.c ary_assoc
  def assoc(k)
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(self)
      v = __fpga_aref(self, i)
      v = nil unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 17 # L:TAG_OBJ L:TT_ARRAY mrb_check_array_type
      __fpga_gc_protect_value(v) # v may be removed from ary by mrb_equal()
      return v if v && __fpga_alen(v) > 0 && __fpga_equal(__fpga_aref(v, 0), k)
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    nil
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_rassoc
  def rassoc(value)
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(self)
      v = __fpga_aref(self, i)
      __fpga_gc_protect_value(v) # v may be removed from ary by mrb_equal()
      if __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 17 # L:TAG_OBJ L:TT_ARRAY
        return v if __fpga_alen(v) > 1 && __fpga_equal(__fpga_aref(v, 1), value)
      end
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    nil
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_at
  def at(pos)
    __fpga_ary_ref(self, __fpga_as_int(pos)) # mrb_ary_entry
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_values_at
  def values_at(*args)
    __fpga_check_argc(args, 0, -1) # MRB_ARGS_ANY
    __fpga_get_values_at(self, __fpga_alen(self), args)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_slice_bang
  def slice!(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    a = __fpga_addr(self)
    __fpga_check_frozen(a) # mrb_ary_modify
    if __fpga_alen(args) == 1
      index = __fpga_aref(args, 0)
      return __fpga_ary_delete_at(self, index) unless __fpga_tag(index) == 7 && __fpga_tt(__fpga_addr(index)) == 19 # L:TAG_OBJ L:TT_RANGE
      bl = __fpga_range_beg_len(index, __fpga_ld32(a + 8), true) # L:A_LEN
      return nil unless bl
      i = __fpga_aref(bl, 0)
      len = __fpga_aref(bl, 1)
    else
      i = __fpga_as_int(__fpga_aref(args, 0)) # mrb_get_args の ii
      len = __fpga_as_int(__fpga_aref(args, 1))
    end
    alen = __fpga_ld32(a + 8) # L:A_LEN
    i += alen if i < 0
    return nil if i < 0 || alen < i
    return nil if len < 0
    return [] if alen == i
    len = alen - i if len > alen - i
    ary = __fpga_ary_subseq(self, i, len) # mrb_ary_new_from_values
    ptr = __fpga_ld32(a + 16) # L:A_PTR
    j = i
    while j < alen - len
      __fpga_stv(ptr + j * 16, __fpga_ldv(ptr + (j + len) * 16)) # L:VALUE
      j += 1
    end
    __fpga_ary_resize(self, alen - len)
    ary
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_compact_bang
  def compact!
    __fpga_ary_compact_bang(self)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_compact
  def compact
    ary = __fpga_ary_subseq(self, 0, __fpga_alen(self)) # mrb_ary_dup
    __fpga_ary_compact_bang(ary)
    ary
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_rotate
  def rotate(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    count = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : 1 # mrb_get_args の |i
    ary = []
    len = __fpga_alen(self)
    return ary if len <= 0
    idx = count < 0 ? len - __fpga_rem(0 - count - 1, len) - 1 : __fpga_rem(count, len) # ~count は 0 - count - 1 (どちらも 0 以上)
    i = 0
    while i < len
      ary.__fpga_push1(__fpga_aref(self, idx))
      idx += 1
      idx = 0 if idx == len
      i += 1
    end
    ary
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_rotate_bang
  def rotate!(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    count = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : 1 # mrb_get_args の |i
    a = __fpga_addr(self)
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # mrb_ary_modify
    p = __fpga_ld32(a + 16) # L:A_PTR
    return self if len == 0 || count == 0
    if count == 1
      v = __fpga_ldv(p)
      i = 1
      while i < len
        __fpga_stv(p + (i - 1) * 16, __fpga_ldv(p + i * 16)) # L:VALUE
        i += 1
      end
      __fpga_stv(p + (len - 1) * 16, v) # L:VALUE
      return self
    end
    idx = count < 0 ? len - __fpga_rem(0 - count - 1, len) - 1 : __fpga_rem(count, len)
    __fpga_ary_rev(p, 0, len)
    __fpga_ary_rev(p, 0, len - idx)
    __fpga_ary_rev(p, len - idx, len)
    self
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_difference
  def difference(*args)
    __fpga_check_argc(args, 0, -1) # MRB_ARGS_ANY
    __fpga_ary_subtract_internal(self, args)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_union_multi
  def union(*args)
    __fpga_check_argc(args, 0, -1) # MRB_ARGS_ANY
    __fpga_ary_union_internal(self, args)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_intersection
  def &(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    __fpga_ary_intersection_internal(self, [other])
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_intersection_multi
  def intersection(*args)
    __fpga_check_argc(args, 0, -1) # MRB_ARGS_ANY
    __fpga_ary_intersection_internal(self, args)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_intersect_p
  def intersect?(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    if __fpga_alen(self) > __fpga_alen(other)
      shorter_ary = other
      longer_ary = self
    else
      shorter_ary = self
      longer_ary = other
    end
    return false if __fpga_alen(shorter_ary) == 0 || __fpga_alen(longer_ary) == 0
    arys = [shorter_ary] # ary_memb_init (D42)
    ai = __fpga_gc_arena_save # ary_intersect_p_body
    i = 0
    while i < __fpga_alen(longer_ary)
      p = __fpga_aref(longer_ary, i)
      __fpga_gc_protect_value(p) # p may be removed from longer_ary by ary_memb_has()
      hit = __fpga_ary_memb_has(arys, p)
      __fpga_gc_arena_restore(ai)
      return true if hit
      i += 1
    end
    false
  end

  # Array#fill の引数を [start, length] に
  # C: mrbgems/mruby-array-ext/src/array.c ary_fill_parse_arg
  def __fill_parse_arg(*args, &block)
    __fpga_check_argc(args, 0, 4) # MRB_ARGS_ARG(0,4)
    argc = __fpga_alen(args)
    __fpga_raise_argnum(argc, 0, 3) if argc > 3 # mrb_get_args の |ooo&
    arg0 = argc > 0 ? __fpga_aref(args, 0) : nil
    arg1 = argc > 1 ? __fpga_aref(args, 1) : nil
    arg2 = argc > 2 ? __fpga_aref(args, 2) : nil
    ary_len = __fpga_alen(self)
    start = 0
    length = 0
    if __fpga_tag(block) > 0 # L:TAG_NIL
      if argc == 0 || __fpga_tag(arg0) == 0 # L:TAG_NIL
        start = 0
        length = ary_len
      elsif __fpga_tag(arg0) == 7 && __fpga_tt(__fpga_addr(arg0)) == 19 # L:TAG_OBJ L:TT_RANGE
        bl = __fpga_range_beg_len(arg0, ary_len, true)
        if bl # MRB_RANGE_OK (MRB_RANGE_OUT の時 C は初期化していない値を読む。ここは 0 のまま)
          start = __fpga_aref(bl, 0)
          length = __fpga_aref(bl, 1)
        end
      else
        start = __fpga_as_int(arg0) # mrb_int
        start += ary_len if start < 0
        start = 0 if start < 0
        if argc == 1 || __fpga_tag(arg1) == 0 # L:TAG_NIL
          length = ary_len - start
        else
          length = __fpga_as_int(arg1)
          length = 0 if length < 0
        end
      end
    elsif argc >= 1 && __fpga_tag(arg0) > 0 # L:TAG_NIL
      if argc == 1 || (__fpga_tag(arg1) == 0 && __fpga_tag(arg2) == 0) # L:TAG_NIL
        start = 0
        length = ary_len
      elsif __fpga_tag(arg1) == 7 && __fpga_tt(__fpga_addr(arg1)) == 19 # L:TAG_OBJ L:TT_RANGE
        bl = __fpga_range_beg_len(arg1, ary_len, true)
        if bl
          start = __fpga_aref(bl, 0)
          length = __fpga_aref(bl, 1)
        end
      elsif __fpga_tag(arg1) > 0 # L:TAG_NIL
        start = __fpga_as_int(arg1)
        start += ary_len if start < 0
        start = 0 if start < 0
        if argc == 2 || __fpga_tag(arg2) == 0 # L:TAG_NIL
          length = ary_len - start
        else
          length = __fpga_as_int(arg2)
          length = 0 if length < 0
        end
      end
    end
    [start, length]
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_fill_exec
  def __fill_exec(start, length, obj)
    start = __fpga_as_int(start) # mrb_get_args の iio
    length = __fpga_as_int(length)
    __fpga_raise(ArgumentError, "negative start index") if start < 0
    __fpga_raise(ArgumentError, "negative length") if length < 0
    a = __fpga_addr(self)
    en = start + length
    __fpga_ary_resize(self, en) if en > __fpga_ld32(a + 8) # L:A_LEN
    if start >= __fpga_ld32(a + 8) || length <= 0 # L:A_LEN
      __fpga_check_frozen(a) # mrb_check_frozen
      return self
    end
    length = __fpga_ld32(a + 8) - start if en > __fpga_ld32(a + 8) # L:A_LEN L:A_LEN
    __fpga_check_frozen(a) # mrb_ary_modify
    ptr = __fpga_ld32(a + 16) + start * 16 # L:A_PTR L:VALUE
    i = 0
    while i < length
      __fpga_stv(ptr + i * 16, obj) # L:VALUE
      i += 1
    end
    self
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_uniq
  def __uniq
    ary = __fpga_ary_subseq(self, 0, __fpga_alen(self)) # mrb_ary_dup
    __fpga_ary_uniq_bang(ary)
    ary
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_uniq_bang
  def __uniq!
    __fpga_ary_uniq_bang(self)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_flatten
  def flatten(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    level = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : -1 # mrb_get_args の |i
    __fpga_aref(__fpga_flatten_internal(self, level), 0)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_flatten_bang
  def flatten!(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    level = __fpga_alen(args) > 0 ? __fpga_as_int(__fpga_aref(args, 0)) : -1 # mrb_get_args の |i
    __fpga_check_frozen(__fpga_addr(self)) # mrb_ary_modify
    r = __fpga_flatten_internal(self, level)
    return nil if __fpga_aref(r, 1) == false
    __fpga_ary_replace_v(self, __fpga_aref(r, 0)) # mrb_ary_replace
    self
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_normalize_index
  def __normalize_index(index_val)
    index = __fpga_as_int(index_val)
    len = __fpga_alen(self)
    index += len if index < 0
    return index if index >= 0 && index < len
    nil
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_fetch
  def __fetch(index_val, default_val, none)
    index = __fpga_as_int(index_val)
    original_index = index
    len = __fpga_alen(self)
    index += len if index < 0
    if index < 0 || index >= len
      if __fpga_tag(default_val) == __fpga_tag(none) && __fpga_int(default_val) == __fpga_int(none) # mrb_obj_equal
        __fpga_raisef(IndexError, "index %i outside of array bounds: %i...%i", [original_index, 0 - len, len])
      end
      return default_val
    end
    __fpga_aref(self, index)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_insert
  def insert(*args)
    __fpga_check_argc(args, 1, -1) # MRB_ARGS_ARG(1,-1)
    idx = __fpga_as_int(__fpga_aref(args, 0)) # mrb_get_args の i*
    argc = __fpga_alen(args) - 1
    a = __fpga_addr(self)
    if argc == 0
      __fpga_check_frozen(a) # mrb_check_frozen
      return self
    end
    len = __fpga_alen(self)
    if idx < 0
      idx += len + 1
      __fpga_raisef(IndexError, "index %i outside of array bounds", [idx - (len + 1)]) if idx < 0
    end
    __fpga_check_frozen(a) # mrb_ary_modify
    __fpga_ary_resize(self, (idx > len ? idx : len) + argc)
    if idx < len
      ptr = __fpga_ld32(a + 16) # L:A_PTR
      __fpga_move(ptr + (idx + argc) * 16, ptr + idx * 16, (len - idx) * 16) # L:VALUE memmove
    end
    i = 0
    while i < argc
      __fpga_ary_set(self, idx + i, __fpga_aref(args, i + 1))
      i += 1
    end
    self
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_deconstruct
  def deconstruct
    self
  end

  # 塊があれば生成器 (D64 の配列 [total, cursor])、無ければ組の全部の配列
  # C: mrbgems/mruby-array-ext/src/array.c ary_product_generate
  def __product_generate(arys_ary, &block)
    __fpga_ensure_array_type(arys_ary) # mrb_get_args の A&
    total = __fpga_alen(self)
    i = 0
    while i < __fpga_alen(arys_ary)
      a = __fpga_aref(arys_ary, i)
      __fpga_check_type_array(a)
      n = __fpga_alen(a)
      if n == 0
        total = 0
        break
      end
      __fpga_raise(ArgumentError, "result too big") if total > 9223372036854775807 / n # mrb_int_mul_overflow
      total *= n
      i += 1
    end
    if __fpga_tag(block) == 0 # L:TAG_NIL
      result = []
      i = 0
      while i < total
        result.__fpga_push1(__fpga_ary_product_fetch(self, arys_ary, i))
        i += 1
      end
      return result
    end
    return [total, 0] if total > 0 # Data_Make_Struct (D64)
    nil
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_product_next
  def __product_next(arys, g)
    __fpga_ensure_array_type(arys) # mrb_get_args の Ad
    cursor = __fpga_aref(g, 1)
    return nil if cursor >= __fpga_aref(g, 0)
    __fpga_ary_set(g, 1, cursor + 1) # g->cursor++
    __fpga_ary_product_fetch(self, arys, cursor)
  end

  # 状態は D64 の配列 [mode, n, k, indices]
  # C: mrbgems/mruby-array-ext/src/array.c ary_combination_init
  def __combination_init(mode_sym, k)
    mode_sym = __fpga_obj_to_sym(mode_sym) # mrb_get_args の ni
    k = __fpga_as_int(k)
    return nil if k < 1 || __fpga_alen(self) < 1
    if mode_sym == __fpga_addr(:repeated_permutation)
      mode = 1 # comb_repeated_permutation
    elsif mode_sym == __fpga_addr(:repeated_combination)
      mode = 2 # comb_repeated_combination
    elsif mode_sym == __fpga_addr(:permutation)
      return nil if k > __fpga_alen(self)
      mode = 3 # comb_permutation
    elsif mode_sym == __fpga_addr(:combination)
      return nil if k > __fpga_alen(self)
      mode = 4 # comb_combination
    else
      __fpga_raise(ArgumentError, "wrong mode")
    end
    indices = [] # mrb_calloc
    i = 0
    while i < k
      indices.__fpga_push1(mode == 3 || mode == 4 ? i : 0)
      i += 1
    end
    [mode, __fpga_alen(self), k, indices]
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_combination_next
  def __combination_next(state)
    mode = __fpga_aref(state, 0)
    return nil if mode == 0 # comb_finished
    n = __fpga_aref(state, 1)
    k = __fpga_aref(state, 2)
    ind = __fpga_aref(state, 3)
    __fpga_raise(RuntimeError, "array modified during iteration") unless __fpga_alen(self) == n
    i = 0
    while i < k
      if __fpga_aref(ind, i) >= n
        __fpga_ary_set(state, 0, 0) # comb_finished
        return nil
      end
      i += 1
    end
    result = []
    i = 0
    while i < k
      result.__fpga_push1(__fpga_aref(self, __fpga_aref(ind, i)))
      i += 1
    end
    if mode == 1 || mode == 2 # comb_repeated_permutation comb_repeated_combination
      i = k - 1
      while i >= 0
        __fpga_ary_set(ind, i, __fpga_aref(ind, i) + 1)
        if __fpga_aref(ind, i) < n
          reset = mode == 1 ? 0 : __fpga_aref(ind, i)
          i += 1
          while i < k
            __fpga_ary_set(ind, i, reset)
            i += 1
          end
          return result
        end
        i -= 1
      end
    elsif mode == 3 # comb_permutation
      i = k - 1
      while i >= 0
        __fpga_ary_set(ind, i, __fpga_aref(ind, i) + 1)
        __fpga_adjust_next_permutation_index(ind, i)
        if __fpga_aref(ind, i) < n
          i += 1
          while i < k
            __fpga_ary_set(ind, i, 0)
            __fpga_adjust_next_permutation_index(ind, i)
            i += 1
          end
          return result
        end
        i -= 1
      end
    elsif mode == 4 # comb_combination
      i = k - 1
      while i >= 0
        __fpga_ary_set(ind, i, __fpga_aref(ind, i) + 1)
        if __fpga_aref(ind, i) <= n - k + i
          i += 1
          while i < k
            __fpga_ary_set(ind, i, __fpga_aref(ind, i - 1) + 1)
            i += 1
          end
          return result
        end
        i -= 1
      end
    else
      result = nil
    end
    __fpga_ary_set(state, 0, 0) # comb_finished
    result
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_max
  def __max
    __fpga_ary_max_min(self, 1)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_min
  def __min
    __fpga_ary_max_min(self, -1)
  end
end

class Object
  # 容量を足りるまで広げる (4 より小さければ 4、足りるまで倍)
  # 先頭に 1 つ入れる
  # C: src/array.c mrb_ary_unshift
  def __fpga_ary_unshift1(ary, item)
    len = __fpga_alen(ary)
    ary.__fpga_push1(nil)
    k = len
    while k > 0
      __fpga_ary_set(ary, k, __fpga_aref(ary, k - 1))
      k -= 1
    end
    __fpga_ary_set(ary, 0, item)
    ary
  end

  # a の中身を b の中身の写しにする
  # C: src/array.c ary_replace
  def __fpga_ary_replace(a, b)
    __fpga_check_frozen(__fpga_addr(a)) # ary_modify_check
    return if __fpga_addr(a) == __fpga_addr(b)
    len = __fpga_alen(b)
    __fpga_st32(__fpga_addr(a) + 8, 0) # L:A_LEN
    k = 0
    while k < len
      __fpga_ary_set(a, k, __fpga_aref(b, k))
      k += 1
    end
  end

  # 自分で置き換えるなら書かないが、凍った配列は FrozenError
  # C: src/array.c mrb_ary_replace
  def __fpga_ary_replace_v(self_, other)
    if __fpga_addr(self_) == __fpga_addr(other)
      __fpga_check_frozen(__fpga_addr(self_)) # ary_modify_check
    else
      __fpga_ary_replace(self_, other)
    end
  end

  # 長さを変える (縮める時に容量は縮めない、D63)。伸ばした所は nil
  # C: src/array.c mrb_ary_resize
  def __fpga_ary_resize(ary, new_len)
    a = __fpga_addr(ary)
    __fpga_check_frozen(a) # ary_modify
    old_len = __fpga_ld32(a + 8) # L:A_LEN
    return ary if old_len == new_len
    if new_len > old_len
      __fpga_ary_expand_capa(a, new_len) if new_len > __fpga_ld32(a + 12) # L:A_CAPA
      k = old_len
      while k < new_len # ary_fill_with_nil
        __fpga_stv(__fpga_ld32(a + 16) + k * 16, nil) # L:A_PTR L:VALUE
        k += 1
      end
    end
    __fpga_st32(a + 8, new_len) # L:A_LEN
    ary
  end

  # C: src/array.c ary_expand_capa
  def __fpga_ary_expand_capa(a, len)
    capa = __fpga_ld32(a + 12) # L:A_CAPA
    capa = 4 if capa < 4 # L:ARY_DEFAULT_LEN
    capa *= 2 while capa < len
    buf = __fpga_realloc(__fpga_ld32(a + 16), capa * 16) # L:A_PTR L:VALUE
    __fpga_st32(a + 16, buf) # L:A_PTR
    __fpga_st32(a + 12, capa) # L:A_CAPA
  end

  # C: src/array.c ary_new_capa
  def __fpga_ary_new_capa(capa)
    __fpga_raise(ArgumentError, "array size too big") if capa > 134217727 # ARY_MAX_SIZE (32bit: SIZE_MAX / sizeof(mrb_value) の 2 の冪)
    a = __fpga_slot(__fpga_addr(__fpga_core(8)), 17) # L:CORE_ARRAY L:TT_ARRAY
    if capa > 0 # MRB_ARY_EMBED は無い (D04)
      __fpga_st32(a + 16, __fpga_malloc(capa * 16)) # L:A_PTR L:VALUE
      __fpga_st32(a + 12, capa) # L:A_CAPA
    end
    a
  end

  # R[idx..idx+argc-1] の配列 (vm.c の ary_new_from_regs)
  # C: src/vm.c ary_new_from_regs
  def __fpga_ary_new_from_regs(argc, idx)
    a = __fpga_ary_new_capa(argc)
    p = __fpga_ld32(a + 16) # L:A_PTR
    k = 0
    while k < argc
      __fpga_stv(p + k * 16, __fpga_reg(idx + k)) # L:VALUE
      k += 1
    end
    __fpga_st32(a + 8, argc) # L:A_LEN
    __fpga_obj(a)
  end

  # OP_ARRAY: R[a] = ary_new(R[a],R[a+1]..R[a+b]) (回路は要素 0 個だけ)
  # C: src/vm.c OP_ARRAY
  def __fpga_op_ARRAY(a, b, c)
    __fpga_setreg(a, __fpga_ary_new_from_regs(b, a))
  end

  # OP_ARRAY2: R[a] = ary_new(R[b],R[b+1]..R[b+c])
  # C: src/vm.c OP_ARRAY2
  def __fpga_op_ARRAY2(a, b, c)
    __fpga_setreg(a, __fpga_ary_new_from_regs(c, b))
  end

  # C: src/array.c ary_subseq
  def __fpga_ary_subseq(ary, beg, len)
    r = []
    k = 0
    while k < len
      r.__fpga_push1(__fpga_aref(ary, beg + k))
      k += 1
    end
    r
  end

  # 添字 (Integer か Float、ほかは mrb_get_args の i)
  # C: src/array.c aget_index
  def __fpga_ary_index(index)
    __fpga_as_int(index)
  end

  # C: src/array.c ary_concat
  def __fpga_ary_concat(a, a2)
    __fpga_check_frozen(__fpga_addr(a)) # ary_replace の ary_modify_check か ary_modify
    len2 = __fpga_alen(a2)
    k = 0
    while k < len2
      a.__fpga_push1(__fpga_aref(a2, k))
      k += 1
    end
  end

  # C: src/array.c mrb_ary_splice
  def __fpga_ary_splice(ary, head, len, rpl)
    alen = __fpga_alen(ary)
    __fpga_check_frozen(__fpga_addr(ary)) # ary_modify
    __fpga_raisef(IndexError, "negative length (%i)", [len]) if len < 0
    if head < 0
      head += alen
      __fpga_raisef(IndexError, "index %i is out of array", [head - alen]) if head < 0
    end
    tail = head + len
    if alen < len || alen < tail
      len = alen - head
      tail = head + len
    end
    argv = if __fpga_tag(rpl) == 7 && __fpga_tt(__fpga_addr(rpl)) == 17 # L:TAG_OBJ L:TT_ARRAY
             __fpga_ary_subseq(rpl, 0, __fpga_alen(rpl)) # 自分を入れる時のため写す (ary_dup)
           elsif __fpga_tag(rpl) == 6 # L:TAG_UNDEF
             []
           else
             [rpl]
           end
    argc = __fpga_alen(argv)
    a = __fpga_addr(ary)
    if head >= alen
      len = head + argc
      __fpga_ary_expand_capa(a, len) if len > __fpga_ld32(a + 12) # L:A_CAPA
      k = alen
      while k < head # ary_fill_with_nil
        __fpga_stv(__fpga_ld32(a + 16) + k * 16, nil) # L:A_PTR L:VALUE
        k += 1
      end
      __fpga_copy(__fpga_ld32(a + 16) + head * 16, __fpga_ld32(__fpga_addr(argv) + 16), argc * 16) if argc > 0 # L:A_PTR L:VALUE
      __fpga_st32(a + 8, len) # L:A_LEN
    else
      newlen = alen + argc - len
      __fpga_ary_expand_capa(a, newlen) if newlen > __fpga_ld32(a + 12) # L:A_CAPA
      ptr = __fpga_ld32(a + 16) # L:A_PTR
      unless len == argc
        __fpga_move(ptr + (head + argc) * 16, ptr + tail * 16, (alen - tail) * 16) # L:VALUE value_move
        __fpga_st32(a + 8, newlen) # L:A_LEN
      end
      __fpga_copy(ptr + head * 16, __fpga_ld32(__fpga_addr(argv) + 16), argc * 16) if argc > 0 # L:A_PTR L:VALUE
    end
    ary
  end

  # 重なってよい写し (memmove。回路の __fpga_copy は重なってよい)
  # C: none (D17)
  def __fpga_move(dst, src, n)
    __fpga_copy(dst, src, n)
  end

  # 入れ子の配列は中へ入って続ける (再帰した配列は ArgumentError)
  # C: src/array.c join_ary
  def __fpga_join_ary(ary, sep)
    result = "" # mrb_str_new_capa(mrb, 64)
    stack = [] # {配列, 添字} の組を積む (C の再帰の代わり)
    idx = 0
    while true
      while idx < __fpga_alen(ary)
        val = __fpga_aref(ary, idx)
        __fpga_str_cat_str(result, sep) if idx > 0 && __fpga_tag(sep) > 0 # L:TAG_NIL
        idx += 1
        as_array = false
        if __fpga_tag(val) == 7 && __fpga_tt(__fpga_addr(val)) == 17 # L:TAG_OBJ L:TT_ARRAY
          as_array = true
        elsif (__fpga_tag(val) == 7 && __fpga_tt(__fpga_addr(val)) == 18) == false # L:TAG_OBJ L:TT_STRING
          val = __fpga_obj_as_string(val) # mrb_check_string_type / mrb_check_array_type は型を見るだけ
        end
        if as_array
          v = __fpga_addr(val)
          __fpga_raise(ArgumentError, "recursive array join") if v == __fpga_addr(ary)
          sp = __fpga_ld32(__fpga_addr(stack) + 16) # L:A_PTR
          se = sp + __fpga_alen(stack) * 16 # L:VALUE
          while sp < se # 今の道の祖先 (組の配列の方)
            __fpga_raise(ArgumentError, "recursive array join") if __fpga_ld32(sp + 12) == v # 値の下位 32bit (番地)
            sp += 16 * 2 # L:VALUE 2 つ
          end
          stack.__fpga_push1(ary)
          stack.__fpga_push1(idx)
          ary = val
          idx = 0
        else
          __fpga_str_cat_str(result, val)
        end
      end
      break if __fpga_alen(stack) == 0
      idx = __fpga_aref(stack, __fpga_alen(stack) - 1)
      ary = __fpga_aref(stack, __fpga_alen(stack) - 2)
      __fpga_st32(__fpga_addr(stack) + 8, __fpga_alen(stack) - 2) # L:A_LEN mrb_ary_pop 2 回
    end
    result
  end

  # --- mruby-array-ext の集合の演算。ary_memb は khash の set を作らず、いつも配列を辿る (D42)
  # 引数を Array に (mrb_check_array_type、Array でなければ TypeError)
  # C: mrbgems/mruby-array-ext/src/array.c ary_get_array_args
  def __fpga_ary_get_array_args(argv)
    converted = []
    i = 0
    while i < __fpga_alen(argv)
      other = __fpga_aref(argv, i)
      __fpga_raise(TypeError, "can't convert passed argument to Array") unless __fpga_tag(other) == 7 && __fpga_tt(__fpga_addr(other)) == 17 # L:TAG_OBJ L:TT_ARRAY
      converted.__fpga_push1(other)
      i += 1
    end
    converted
  end

  # v が arys のどれかの要素と eql? か (ary_elem_eql は mrb_eql)
  # C: mrbgems/mruby-array-ext/src/array.c ary_memb_has (D42)
  def __fpga_ary_memb_has(arys, v)
    i = 0
    while i < __fpga_alen(arys)
      ary = __fpga_aref(arys, i)
      j = 0
      while j < __fpga_alen(ary)
        return true if __fpga_eql(v, __fpga_aref(ary, j))
        j += 1
      end
      i += 1
    end
    false
  end

  # kept の前の kept_len 個に v と eql? なものが無ければ真 (初めて会う)
  # C: mrbgems/mruby-array-ext/src/array.c ary_memb_first (D42)
  def __fpga_ary_memb_first(v, kept, kept_len)
    i = 0
    while i < kept_len && i < __fpga_alen(kept)
      return false if __fpga_eql(v, __fpga_aref(kept, i))
      i += 1
    end
    true
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_subtract_internal
  def __fpga_ary_subtract_internal(ary, argv)
    return __fpga_ary_subseq(ary, 0, __fpga_alen(ary)) if __fpga_alen(argv) == 0 # mrb_ary_dup
    argv = __fpga_ary_get_array_args(argv)
    result = []
    ai = __fpga_gc_arena_save # ary_subtract_body
    i = 0
    while i < __fpga_alen(ary)
      p = __fpga_aref(ary, i)
      __fpga_gc_protect_value(p) # p may be removed from self by ary_memb_has()
      result.__fpga_push1(p) unless __fpga_ary_memb_has(argv, p)
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    result
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_union_add
  def __fpga_ary_union_add(src, result)
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(src)
      elem = __fpga_aref(src, i)
      __fpga_gc_protect_value(elem) # elem may be removed from src by ary_memb_first()
      result.__fpga_push1(elem) if __fpga_ary_memb_first(elem, result, __fpga_alen(result))
      __fpga_gc_arena_restore(ai)
      i += 1
    end
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_union_internal
  def __fpga_ary_union_internal(ary, argv)
    argv = __fpga_ary_get_array_args(argv)
    result = []
    __fpga_ary_union_add(ary, result) # ary_union_body
    i = 0
    while i < __fpga_alen(argv)
      __fpga_ary_union_add(__fpga_aref(argv, i), result)
      i += 1
    end
    result
  end

  # v の要素と arys[sel] の要素が eql? で、kept の前の kept_len 個に無ければ真 (配れる。D42 の配列を辿る方)
  # C: mrbgems/mruby-array-ext/src/array.c ary_memb_take (D42)
  def __fpga_ary_memb_take(arys, sel, v, kept, kept_len)
    ary = __fpga_aref(arys, sel)
    found = false
    i = 0
    while i < __fpga_alen(ary)
      if __fpga_eql(v, __fpga_aref(ary, i))
        found = true
        break
      end
      i += 1
    end
    return false if found == false
    __fpga_ary_memb_first(v, kept, kept_len)
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_intersection_internal
  def __fpga_ary_intersection_internal(ary, argv)
    return __fpga_ary_subseq(ary, 0, __fpga_alen(ary)) if __fpga_alen(argv) == 0 # mrb_ary_new_from_values
    argv = __fpga_ary_get_array_args(argv)
    result = []
    j = 0 # ary_intersection_body
    while j < __fpga_alen(argv)
      src = j > 0 ? result : ary
      write_pos = 0
      ai = __fpga_gc_arena_save
      i = 0
      while i < __fpga_alen(src)
        p = __fpga_aref(src, i)
        __fpga_gc_protect_value(p) # p may be removed from src by ary_memb_take()
        if __fpga_ary_memb_take(argv, j, p, result, j == 0 ? write_pos : 0)
          if j == 0
            result.__fpga_push1(p)
          else
            __fpga_stv(__fpga_ld32(__fpga_addr(result) + 16) + write_pos * 16, p) # L:A_PTR L:VALUE
          end
          write_pos += 1
        end
        __fpga_gc_arena_restore(ai)
        i += 1
      end
      __fpga_ary_resize(result, write_pos) if j > 0
      break if write_pos == 0
      j += 1
    end
    result
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_uniq_bang
  def __fpga_ary_uniq_bang(ary)
    len = __fpga_alen(ary)
    a = __fpga_addr(ary)
    __fpga_check_frozen(a) # len <= 1 は mrb_check_frozen、ほかは mrb_ary_modify
    return nil if len <= 1
    write_pos = 0 # ary_uniq_bang_body (D42)
    ai = __fpga_gc_arena_save
    read_pos = 0
    while read_pos < __fpga_alen(ary)
      elem = __fpga_aref(ary, read_pos)
      __fpga_gc_protect_value(elem) # elem may be removed from self by ary_memb_first()
      if __fpga_ary_memb_first(elem, ary, write_pos)
        if (write_pos == read_pos) == false && write_pos < __fpga_alen(ary)
          __fpga_stv(__fpga_ld32(a + 16) + write_pos * 16, elem) # L:A_PTR L:VALUE
        end
        write_pos += 1
      end
      __fpga_gc_arena_restore(ai)
      read_pos += 1
    end
    return nil if write_pos == len
    __fpga_ary_resize(ary, write_pos)
    ary
  end

  # [結果, 平らにしたか] を返す (C は modified に書く)
  # C: mrbgems/mruby-array-ext/src/array.c flatten_internal
  def __fpga_flatten_internal(self_, level)
    modified = false
    result = []
    stack = [self_, 0, 1] # 配列、添字、深さ
    while __fpga_alen(stack) > 0
      depth = __fpga_ary_pop(stack)
      idx = __fpga_ary_pop(stack)
      ary = __fpga_ary_pop(stack)
      while idx < __fpga_alen(ary)
        e = __fpga_ary_ref(ary, idx) # mrb_ary_entry
        idx += 1
        if __fpga_tag(e) == 7 && __fpga_tt(__fpga_addr(e)) == 17 && (level < 0 || depth <= level) # L:TAG_OBJ L:TT_ARRAY
          if level < 0
            __fpga_raise(ArgumentError, "tried to flatten recursive array") if __fpga_addr(e) == __fpga_addr(ary)
            j = 0
            while j < __fpga_alen(stack)
              __fpga_raise(ArgumentError, "tried to flatten recursive array") if __fpga_addr(e) == __fpga_addr(__fpga_aref(stack, j))
              j += 3
            end
          end
          modified = true
          stack.__fpga_push1(ary)
          stack.__fpga_push1(idx)
          stack.__fpga_push1(depth)
          ary = e
          idx = 0
          depth += 1
        else
          result.__fpga_push1(e)
        end
      end
    end
    [result, modified]
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_compact_bang
  def __fpga_ary_compact_bang(ary)
    a = __fpga_addr(ary)
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # mrb_ary_modify
    ptr = __fpga_ld32(a + 16) # L:A_PTR
    i = 0
    j = 0
    while i < len
      v = __fpga_ldv(ptr + i * 16) # L:VALUE
      unless __fpga_tag(v) == 0 # L:TAG_NIL
        __fpga_stv(ptr + j * 16, v) unless i == j # L:VALUE
        j += 1
      end
      i += 1
    end
    return nil if i == j
    __fpga_st32(a + 8, j) # L:A_LEN
    ary
  end

  # p の [beg, en) を逆に
  # C: mrbgems/mruby-array-ext/src/array.c rev
  def __fpga_ary_rev(p, beg, en)
    i = beg
    j = en - 1
    while i < j
      v = __fpga_ldv(p + i * 16) # L:VALUE
      __fpga_stv(p + i * 16, __fpga_ldv(p + j * 16)) # L:VALUE
      __fpga_stv(p + j * 16, v) # L:VALUE
      i += 1
      j -= 1
    end
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_product_fetch
  def __fpga_ary_product_fetch(self_ary, arys_ary, n)
    j = __fpga_alen(arys_ary)
    group = []
    while j > 0
      j -= 1
      a = __fpga_aref(arys_ary, j)
      __fpga_check_type_array(a)
      b = __fpga_alen(a)
      __fpga_raise(ArgumentError, "cannot compute product with an empty array") if b <= 0
      __fpga_ary_set(group, j + 1, __fpga_aref(a, __fpga_rem(n, b)))
      n /= b
    end
    __fpga_raise(IndexError, "index out of range") if n >= __fpga_alen(self_ary)
    __fpga_ary_set(group, 0, __fpga_aref(self_ary, n))
    group
  end

  # C: mrbgems/mruby-array-ext/src/array.c adjust_next_permutation_index
  def __fpga_adjust_next_permutation_index(ind, i)
    j = i - 1
    while j >= 0
      if __fpga_aref(ind, i) == __fpga_aref(ind, j)
        __fpga_ary_set(ind, i, __fpga_aref(ind, i) + 1)
        j = i
      end
      j -= 1
    end
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_max_min
  def __fpga_ary_max_min(ary, want)
    return nil if __fpga_alen(ary) == 0
    result = __fpga_aref(ary, 0)
    ai = __fpga_gc_arena_save
    i = 1
    while i < __fpga_alen(ary)
      val = __fpga_aref(ary, i)
      result = val if __fpga_ary_cmp_ordered(val, result) == want
      __fpga_gc_arena_restore(ai)
      __fpga_gc_protect_value(result)
      i += 1
    end
    result
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_cmp_ordered
  def __fpga_ary_cmp_ordered(a, b)
    cmp = __fpga_cmp(a, b)
    __fpga_raisef(ArgumentError, "comparison of %T with %T failed", [a, b]) if cmp == -2
    cmp
  end

  # mrb_check_type(x, MRB_TT_ARRAY)
  # C: src/object.c mrb_check_type
  def __fpga_check_type_array(x)
    return if __fpga_tag(x) == 7 && __fpga_tt(__fpga_addr(x)) == 17 # L:TAG_OBJ L:TT_ARRAY
    t = __fpga_tag(x)
    if t == 0 # L:TAG_NIL
      ename = "nil"
    elsif t == 3 # L:TAG_INT
      ename = "Integer"
    elsif t == 4 # L:TAG_SYM
      ename = "Symbol"
    elsif t < 7 # L:TAG_OBJ mrb_immediate_p
      ename = __fpga_obj_as_string(x)
    else
      ename = __fpga_mod_to_s(__fpga_obj_class(x)) # mrb_obj_classname
    end
    __fpga_raisef(TypeError, "wrong argument type %S (expected Array)", [ename])
  end

  # 整数の添字と Range を並べた選び方で、func (ここは mrb_ary_entry) の値を集める
  # C: src/range.c mrb_get_values_at
  def __fpga_get_values_at(obj, olen, argv)
    result = []
    i = 0
    while i < __fpga_alen(argv)
      v = __fpga_aref(argv, i)
      if __fpga_tag(v) == 3 # L:TAG_INT
        result.__fpga_push1(__fpga_ary_ref(obj, v))
      else
        bl = __fpga_range_beg_len(v, olen, false)
        __fpga_raisef(TypeError, "invalid values selector: %v", [v]) unless bl
        beg = __fpga_aref(bl, 0)
        len = __fpga_aref(bl, 1)
        en = olen < beg + len ? olen : beg + len
        j = beg
        while j < en
          result.__fpga_push1(__fpga_ary_ref(obj, j))
          j += 1
        end
        while j < beg + len
          result.__fpga_push1(nil)
          j += 1
        end
      end
      i += 1
    end
    result
  end

  # C: src/array.c mrb_ary_pop
  def __fpga_ary_pop(ary)
    len = __fpga_alen(ary)
    __fpga_check_frozen(__fpga_addr(ary)) # ary_modify_check
    return nil if len == 0
    __fpga_st32(__fpga_addr(ary) + 8, len - 1) # L:A_LEN
    __fpga_aref(ary, len - 1)
  end

  # C: src/array.c mrb_ary_shift
  def __fpga_ary_shift(ary)
    a = __fpga_addr(ary)
    len = __fpga_ld32(a + 8) # L:A_LEN
    __fpga_check_frozen(a) # ary_modify_check
    return nil if len == 0
    ptr = __fpga_ld32(a + 16) # L:A_PTR
    val = __fpga_ldv(ptr)
    __fpga_move(ptr, ptr + 16, (len - 1) * 16) # L:VALUE ARY_SHIFT_SHARED_MIN の共有 (ary_make_shared) は写さず、いつも前へ詰める (D63)
    __fpga_st32(a + 8, len - 1) # L:A_LEN
    val
  end

  # 抜いた後に容量を縮めない (ary_shrink_capa、D63)
  # C: src/array.c mrb_ary_delete_at
  def __fpga_ary_delete_at(ary, index)
    index = __fpga_as_int(index)
    a = __fpga_addr(ary)
    alen = __fpga_ld32(a + 8) # L:A_LEN
    index += alen if index < 0
    return nil if index < 0 || alen <= index
    __fpga_check_frozen(a) # ary_modify
    ptr = __fpga_ld32(a + 16) + index * 16 # L:A_PTR L:VALUE
    val = __fpga_ldv(ptr)
    len = alen - index - 1
    while len > 0
      __fpga_stv(ptr, __fpga_ldv(ptr + 16)) # L:VALUE
      ptr += 16 # L:VALUE
      len -= 1
    end
    __fpga_st32(a + 8, alen - 1) # L:A_LEN
    val
  end

  # --- sort! の比べ方 (array.c)
  # C: src/array.c ary_all_fixnum_p
  def __fpga_ary_all_fixnum_p(a, n)
    i = 0
    while i < n
      return false unless __fpga_tag(__fpga_ldv(a + i * 16)) == 3 # L:VALUE L:TAG_INT
      i += 1
    end
    true
  end

  # C: src/array.c heapify_fixnum
  def __fpga_heapify_fixnum(a, index, size)
    v = __fpga_ldv(a + index * 16) # L:VALUE
    val = __fpga_int(v)
    while true
      child = 2 * index + 1
      break if child >= size
      child += 1 if child + 1 < size && __fpga_int(__fpga_ldv(a + (child + 1) * 16)) > __fpga_int(__fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      c = __fpga_ldv(a + child * 16) # L:VALUE
      break if __fpga_int(c) <= val
      __fpga_stv(a + index * 16, c) # L:VALUE
      index = child
    end
    __fpga_stv(a + index * 16, v) # L:VALUE SET_FIXNUM_VALUE
  end

  # C: src/array.c heap_delete_root_fixnum
  def __fpga_heap_delete_root_fixnum(a, size)
    lv = __fpga_ldv(a)
    last = __fpga_int(lv)
    hole = 0
    child = 1
    while child + 1 < size
      child += 1 if __fpga_int(__fpga_ldv(a + (child + 1) * 16)) > __fpga_int(__fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
      child = 2 * hole + 1
    end
    if child < size
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
    end
    while hole > 0
      parent = (hole - 1) / 2
      pv = __fpga_ldv(a + parent * 16) # L:VALUE
      break if __fpga_int(pv) >= last
      __fpga_stv(a + hole * 16, pv) # L:VALUE
      hole = parent
    end
    __fpga_stv(a + hole * 16, lv) # L:VALUE
  end

  # C: src/array.c insertion_sort_fixnum
  def __fpga_insertion_sort_fixnum(a, size)
    i = 1
    while i < size
      kv = __fpga_ldv(a + i * 16) # L:VALUE
      key = __fpga_int(kv)
      j = i - 1
      while j >= 0
        jv = __fpga_ldv(a + j * 16) # L:VALUE
        break unless __fpga_int(jv) > key
        __fpga_stv(a + (j + 1) * 16, jv) # L:VALUE
        j -= 1
      end
      __fpga_stv(a + (j + 1) * 16, kv) # L:VALUE
      i += 1
    end
  end

  # String の子の class の物は外す
  # C: src/array.c ary_all_string_p
  def __fpga_ary_all_string_p(a, n)
    sc = __fpga_addr(String)
    i = 0
    while i < n
      v = __fpga_ldv(a + i * 16) # L:VALUE
      return false unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 18 # L:TAG_OBJ L:TT_STRING
      return false unless __fpga_ld32(__fpga_addr(v) + 0) == sc # L:H_CLASS
      i += 1
    end
    true
  end

  # C: src/array.c heapify_str
  def __fpga_heapify_str(a, index, size)
    val = __fpga_ldv(a + index * 16) # L:VALUE
    while true
      child = 2 * index + 1
      break if child >= size
      child += 1 if child + 1 < size && __fpga_str_cmp(__fpga_ldv(a + (child + 1) * 16), __fpga_ldv(a + child * 16)) > 0 # L:VALUE L:VALUE
      c = __fpga_ldv(a + child * 16) # L:VALUE
      break if __fpga_str_cmp(c, val) <= 0
      __fpga_stv(a + index * 16, c) # L:VALUE
      index = child
    end
    __fpga_stv(a + index * 16, val) # L:VALUE
  end

  # C: src/array.c heap_delete_root_str
  def __fpga_heap_delete_root_str(a, size)
    last = __fpga_ldv(a)
    hole = 0
    child = 1
    while child + 1 < size
      child += 1 if __fpga_str_cmp(__fpga_ldv(a + (child + 1) * 16), __fpga_ldv(a + child * 16)) > 0 # L:VALUE L:VALUE
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
      child = 2 * hole + 1
    end
    if child < size
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
    end
    while hole > 0
      parent = (hole - 1) / 2
      pv = __fpga_ldv(a + parent * 16) # L:VALUE
      break if __fpga_str_cmp(pv, last) >= 0
      __fpga_stv(a + hole * 16, pv) # L:VALUE
      hole = parent
    end
    __fpga_stv(a + hole * 16, last) # L:VALUE
  end

  # C: src/array.c insertion_sort_str
  def __fpga_insertion_sort_str(a, size)
    i = 1
    while i < size
      key = __fpga_ldv(a + i * 16) # L:VALUE
      j = i - 1
      while j >= 0
        jv = __fpga_ldv(a + j * 16) # L:VALUE
        break unless __fpga_str_cmp(jv, key) > 0
        __fpga_stv(a + (j + 1) * 16, jv) # L:VALUE
        j -= 1
      end
      __fpga_stv(a + (j + 1) * 16, key) # L:VALUE
      i += 1
    end
  end

  # 塊の答えの符号: Integer はそのまま、nil は ArgumentError、ほかは > 0 と < 0 を送る
  # C: src/array.c cmpint
  def __fpga_cmpint(c, a, b)
    return c if __fpga_tag(c) == 3 # L:TAG_INT
    __fpga_raisef(ArgumentError, "comparison of %T with %T failed", [a, b]) if __fpga_tag(c) == 0 # L:TAG_NIL
    return 1 if __fpga_sendv(c, :>, [0], nil, true) # mrb_funcall_argv1
    return -1 if __fpga_sendv(c, :<, [0], nil, true) # mrb_funcall_argv1
    0
  end

  # a_val が b_val より大きいか。比べている間に配列が変わったら RuntimeError
  # C: src/array.c sort_cmp
  def __fpga_sort_cmp(ary, a_val, b_val, &blk)
    ad = __fpga_addr(ary)
    p = __fpga_ld32(ad + 16) # L:A_PTR
    n = __fpga_ld32(ad + 8) # L:A_LEN
    ai = __fpga_gc_arena_save
    if __fpga_tag(blk) == 0 # L:TAG_NIL
      ta = __fpga_tag(a_val)
      if ta == 3 && __fpga_tag(b_val) == 3 # L:TAG_INT L:TAG_INT
        a_i = __fpga_int(a_val)
        b_i = __fpga_int(b_val)
        cmp = a_i > b_i ? 1 : (a_i < b_i ? -1 : 0)
      elsif ta == 5 && __fpga_tag(b_val) == 5 # L:TAG_FLOAT L:TAG_FLOAT
        cmp = __fpga_f64_cmp(__fpga_int(a_val), __fpga_int(b_val))
        cmp = -2 if cmp == 2 # NaN
      elsif ta == 7 && __fpga_tt(__fpga_addr(a_val)) == 18 && __fpga_tag(b_val) == 7 && __fpga_tt(__fpga_addr(b_val)) == 18 # L:TAG_OBJ L:TT_STRING L:TAG_OBJ L:TT_STRING
        cmp = __fpga_str_cmp(a_val, b_val)
      else
        cmp = __fpga_cmp(a_val, b_val) # mrb_cmp
      end
      if cmp == -2
        __fpga_gc_arena_restore(ai)
        __fpga_raise(ArgumentError, "comparison failed")
      end
    else
      c = yield(a_val, b_val) # mrb_yield_argv
      cmp = __fpga_cmpint(c, a_val, b_val)
    end
    __fpga_gc_arena_restore(ai)
    __fpga_raise(RuntimeError, "array modified during sort") unless __fpga_ld32(ad + 16) == p && __fpga_ld32(ad + 8) == n # L:A_PTR L:A_LEN
    cmp > 0
  end

  # C: src/array.c heapify
  def __fpga_heapify(ary, a, index, size, &blk)
    ai = __fpga_gc_arena_save
    val = __fpga_ldv(a + index * 16) # L:VALUE save root to hole
    __fpga_gc_protect_value(val)
    while true
      child = 2 * index + 1
      break if child >= size
      child += 1 if child + 1 < size && __fpga_sort_cmp(ary, __fpga_ldv(a + (child + 1) * 16), __fpga_ldv(a + child * 16), &blk) # L:VALUE L:VALUE
      c = __fpga_ldv(a + child * 16) # L:VALUE
      break if __fpga_sort_cmp(ary, c, val, &blk) == false
      __fpga_stv(a + index * 16, c) # L:VALUE
      index = child
    end
    __fpga_stv(a + index * 16, val) # L:VALUE place saved value
    __fpga_gc_arena_restore(ai)
  end

  # C: src/array.c heap_delete_root
  def __fpga_heap_delete_root(ary, a, size, &blk)
    ai = __fpga_gc_arena_save
    last = __fpga_ldv(a)
    __fpga_gc_protect_value(last)
    hole = 0
    child = 1
    while child + 1 < size
      child += 1 if __fpga_sort_cmp(ary, __fpga_ldv(a + (child + 1) * 16), __fpga_ldv(a + child * 16), &blk) # L:VALUE L:VALUE
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
      child = 2 * hole + 1
    end
    if child < size
      __fpga_stv(a + hole * 16, __fpga_ldv(a + child * 16)) # L:VALUE L:VALUE
      hole = child
    end
    while hole > 0
      parent = (hole - 1) / 2
      pv = __fpga_ldv(a + parent * 16) # L:VALUE
      break if __fpga_sort_cmp(ary, last, pv, &blk) == false
      __fpga_stv(a + hole * 16, pv) # L:VALUE
      hole = parent
    end
    __fpga_stv(a + hole * 16, last) # L:VALUE
    __fpga_gc_arena_restore(ai)
  end

  # C: src/array.c insertion_sort
  def __fpga_insertion_sort(ary, a, size, &blk)
    ai = __fpga_gc_arena_save
    i = 1
    while i < size
      key = __fpga_ldv(a + i * 16) # L:VALUE
      j = i - 1
      __fpga_gc_protect_value(key) # Protect key from GC - it's temporarily out of the array during sort
      while j >= 0
        jv = __fpga_ldv(a + j * 16) # L:VALUE
        break unless __fpga_sort_cmp(ary, jv, key, &blk)
        __fpga_stv(a + (j + 1) * 16, jv) # L:VALUE
        j -= 1
      end
      __fpga_stv(a + (j + 1) * 16, key) # L:VALUE
      __fpga_gc_arena_restore(ai)
      i += 1
    end
  end

  # C の関数を呼ぶ前の引数の数の検査 (aspec の min と max、max が -1 は上限無し)
  # C: src/vm.c check_argument_count
  def __fpga_check_argc(args, min, max)
    argc = __fpga_alen(args)
    __fpga_raise_argnum(argc, min, max) if argc < min || (max >= 0 && argc > max)
  end

  # C: src/error.c mrb_argnum_error
  def __fpga_raise_argnum(argc, min, max)
    return __fpga_raisef(ArgumentError, "wrong number of arguments (given %i, expected %d)", [argc, min]) if min == max
    return __fpga_raisef(ArgumentError, "wrong number of arguments (given %i, expected %d+)", [argc, min]) if max < 0
    __fpga_raisef(ArgumentError, "wrong number of arguments (given %i, expected %d..%d)", [argc, min, max])
  end
end
