# firmware: Array の C の所 (mruby の src/array.c と mruby-array-ext)。配列の部分 (ary_subseq) は共有せずに写す
# (mruby は長い部分を共有して書く時に写すが、見える意味は同じ)。再帰した配列の inspect の印 (MRB_RECURSIVE_UNARY_P) は S5。
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
    i = 0
    while i < __fpga_alen(self)
      a = __fpga_aref(self, i)
      b = __fpga_aref(ary2, i)
      unless __fpga_tag(a) == __fpga_tag(b) && __fpga_int(a) == __fpga_int(b) # mrb_obj_eq
        return false unless a == b
      end
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
    i = 0
    while i < size
      __fpga_ary_set(self, i, __fpga_tag(blk) == 0 ? obj : yield(i)) # L:TAG_NIL mrb_yield
      i += 1
    end
    self
  end

  # C: src/array.c mrb_ary_replace_m
  def replace(other)
    __fpga_ensure_array_type(other) # mrb_get_args の A
    __fpga_ary_replace(self, other) unless __fpga_addr(self) == __fpga_addr(other) # mrb_ary_replace
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
    len = __fpga_alen(self)
    return nil if len == 0
    __fpga_st32(__fpga_addr(self) + 8, len - 1) # L:A_LEN
    __fpga_aref(self, len - 1)
  end

  # C: src/array.c mrb_ary_clear
  def clear
    __fpga_check_frozen(__fpga_addr(self)) # ary_modify の ary_modify_check
    __fpga_st32(__fpga_addr(self) + 8, 0) # L:A_LEN
    self
  end

  # C: src/array.c mrb_ary_to_s
  def to_s
    ret = "["
    i = 0
    while i < __fpga_alen(self)
      __fpga_str_cat_str(ret, ", ") if i > 0
      __fpga_str_cat_str(ret, __fpga_inspect(__fpga_aref(self, i)))
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
    i = 0
    while i < __fpga_alen(self)
      return false unless __fpga_aref(self, i).eql?(__fpga_aref(ary2, i))
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

  # C: src/array.c ary_expand_capa
  def __fpga_ary_expand_capa(a, len)
    capa = __fpga_ld32(a + 12) # L:A_CAPA
    capa = 4 if capa < 4 # L:ARY_DEFAULT_LEN
    capa *= 2 while capa < len
    buf = __fpga_alloc(capa * 16) # L:VALUE
    __fpga_copy(buf, __fpga_ld32(a + 16), __fpga_ld32(a + 8) * 16) # L:A_PTR L:A_LEN L:VALUE
    __fpga_st32(a + 16, buf) # L:A_PTR
    __fpga_st32(a + 12, capa) # L:A_CAPA
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

  # 重なってよい写し (memmove)
  # C: none (D17)
  def __fpga_move(dst, src, n)
    tmp = __fpga_alloc(n > 0 ? n : 1)
    __fpga_copy(tmp, src, n)
    __fpga_copy(dst, tmp, n)
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
    i = 0 # ary_subtract_body
    while i < __fpga_alen(ary)
      p = __fpga_aref(ary, i)
      result.__fpga_push1(p) unless __fpga_ary_memb_has(argv, p)
      i += 1
    end
    result
  end

  # C: mrbgems/mruby-array-ext/src/array.c ary_union_add
  def __fpga_ary_union_add(src, result)
    i = 0
    while i < __fpga_alen(src)
      elem = __fpga_aref(src, i)
      result.__fpga_push1(elem) if __fpga_ary_memb_first(elem, result, __fpga_alen(result))
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
