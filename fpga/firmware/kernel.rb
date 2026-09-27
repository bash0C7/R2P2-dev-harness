# firmware: Kernel の C の所 (mruby の src/kernel.c、picoruby-machine の Kernel#puts / print は IO を通すが、FPGA はコンソールの
# primitive に直接書く) と BasicObject#method_missing (src/class.c、src/error.c)。
module Kernel
  # puts (mruby の mrblib には無く、picoruby-machine の kernel.rb が $stdout に渡す。改行で終わらなければ改行を足す)
  # C: none (D40)
  def puts(*args)
    n = __fpga_alen(args)
    if n == 0
      __fpga_putc(10)
      return nil
    end
    i = 0
    while i < n
      s = __fpga_aref(args, i).to_s
      __fpga_write_str(s)
      len = s.bytesize
      __fpga_putc(10) unless len > 0 && s.getbyte(len - 1) == 10
      i += 1
    end
    nil
  end

  # C: src/kernel.c mrb_print_m
  def print(*args)
    i = 0
    while i < __fpga_alen(args)
      __fpga_write_str(__fpga_aref(args, i).to_s)
      i += 1
    end
    nil
  end

  # C: picoruby-machine/src/mruby/machine.c print_sub
  def __fpga_write_str(s)
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
  # == / equal? は同じものか (class.c の mrb_obj_equal_m、即値は値で)
  # C: src/class.c mrb_obj_equal_m
  def ==(o)
    __fpga_tag(self) == __fpga_tag(o) && __fpga_int(self) == __fpga_int(o)
  end

  # C: src/class.c mrb_obj_equal_m
  def equal?(o)
    __fpga_tag(self) == __fpga_tag(o) && __fpga_int(self) == __fpga_int(o)
  end

  # != は == を送って反す (class.c の mrb_obj_not_equal_m)
  # C: src/class.c neq_iseq
  def !=(o)
    self == o ? false : true
  end

  # C: src/class.c mrb_bob_not
  def !
    self ? false : true
  end

  # C: src/class.c mrb_obj_missing
  def method_missing(*args)
    __fpga_check_argc(args, 1, -1) # mrb_get_args の n*!
    name = __fpga_aref(args, 0)
    rest = __fpga_ary_subseq(args, 1, __fpga_alen(args) - 1)
    __fpga_no_method_error(__fpga_obj_to_sym(name), rest, "undefined method '%n' for %T", [name, self]) # mrb_method_missing
  end
end

module Kernel
  # C: src/kernel.c mrb_obj_not_match
  def !~(arg)
    (self =~ arg) ? false : true
  end

  # <=>: 呼び出しの鎖に同じ self と引数の <=> があれば nil (再帰の印)、== なら 0
  # C: src/kernel.c mrb_cmp_m
  def <=>(arg)
    ci = __fpga_ld32(__fpga_image(0) + 12) - 64 # L:IMG_c L:CTX_CI L:CI_SIZE ci[-1]
    base = __fpga_cibase
    cmp = __fpga_addr(:<=>)
    while ci >= base
      if __fpga_ld32(ci + 4) == cmp # L:CI_MID
        s = __fpga_ld32(ci + 16) # L:CI_STACK
        a0 = __fpga_ldv(s)
        a1 = __fpga_ldv(s + 16) # L:VALUE
        if __fpga_tag(a0) == __fpga_tag(self) && __fpga_int(a0) == __fpga_int(self) && __fpga_tag(a1) == __fpga_tag(arg) && __fpga_int(a1) == __fpga_int(arg)
          return nil
        end
      end
      ci -= 64 # L:CI_SIZE
    end
    __fpga_equal(self, arg) ? 0 : nil
  end

  # C: src/kernel.c mrb_f_block_given_p_m
  def block_given?
    __fpga_block_given
  end

  alias iterator? block_given? # kernel.c は block_given? と iterator? に同じ関数を置く

  # C: src/kernel.c mrb_f_block_given_p_m
  def self.block_given?
    __fpga_block_given
  end

  # C: src/kernel.c mrb_f_block_given_p_m
  def self.iterator?
    __fpga_block_given
  end

  # C: src/kernel.c mrb_f_raise
  def self.raise(*args)
    __fpga_check_argc(args, 0, 2) # MRB_ARGS_OPT(2)
    __fpga_sendv(self, :raise, args, nil, true) # 同じ関数 (Kernel#raise)
  end

  # C: src/class.c mrb_obj_clone
  def clone
    __fpga_obj_clone(self)
  end

  # C: src/kernel.c obj_is_instance_of
  def instance_of?(c)
    __fpga_raisef(TypeError, "%v is not a class", [c]) unless __fpga_tag(c) == 7 && __fpga_class_p(__fpga_addr(c)) # L:TAG_OBJ mrb_get_args の c (ensure_class_type)
    __fpga_addr(__fpga_obj_class(self)) == __fpga_addr(c)
  end

  # C: src/kernel.c mrb_obj_id_m
  def object_id
    __fpga_obj_id(self)
  end

  # C: src/string.c mrb_encoding
  def __ENCODING__
    "UTF-8"
  end

  # C: src/kernel.c mrb_obj_method_recursive_p
  def __method_recursive?(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    mid = __fpga_obj_to_sym(__fpga_aref(args, 0))
    arg2 = __fpga_alen(args) == 2 ? __fpga_aref(args, 1) : nil
    ci = __fpga_ld32(__fpga_image(0) + 12) - 128 # L:IMG_c L:CTX_CI ci[-2] (2 * CI_SIZE)
    base = __fpga_cibase
    while ci >= base
      s = __fpga_ld32(ci + 16) # L:CI_STACK
      a0 = __fpga_ldv(s)
      if __fpga_ld32(ci + 4) == mid && __fpga_tag(a0) == __fpga_tag(self) && __fpga_int(a0) == __fpga_int(self) # L:CI_MID
        return true if __fpga_alen(args) == 1 || __fpga_tag(arg2) == 0 # L:TAG_NIL
        a1 = __fpga_ldv(s + 16) # L:VALUE
        return true if __fpga_tag(a1) == __fpga_tag(arg2) && __fpga_int(a1) == __fpga_int(arg2)
      end
      ci -= 64 # L:CI_SIZE
    end
    false
  end
end

class Object
  # 呼んだメソッドにブロックが渡されたか (ci[-1] から、メソッドの Proc の env か ci の blk の枠)
  # C: src/kernel.c mrb_f_block_given_p_m
  def __fpga_block_given
    ci = __fpga_ld32(__fpga_image(0) + 12) - 128 # L:IMG_c L:CTX_CI ci[-1] (この helper と block_given? の 2 つ上)
    base = __fpga_cibase
    return false if ci <= base
    p = __fpga_ld32(ci + 8) # L:CI_PROC
    e = 0
    while p > 0
      break if __fpga_and(__fpga_ld32(p + 24), 2048) > 0 # L:P_FLAGS L:PROC_SCOPE
      e = __fpga_proc_env(p)
      p = __fpga_ld32(p + 12) # L:P_UPPER
    end
    return false if p == 0
    if e > 0
      bidx = __fpga_env_bidx(e)
      return false if bidx < 0
      return __fpga_tag(__fpga_ldv(__fpga_ld32(e + 8) + bidx * 16)) > 0 # L:E_STACK L:VALUE L:TAG_NIL
    end
    while base < ci
      break if __fpga_ld32(ci + 8) == p # L:CI_PROC
      ci -= 64 # L:CI_SIZE
    end
    if ci == base
      e = __fpga_proc_env(p)
      return false if e == 0
      bidx = __fpga_env_bidx(e)
      return false if bidx < 0
      return __fpga_tag(__fpga_ldv(__fpga_ld32(e + 8) + bidx * 16)) > 0 # L:E_STACK L:VALUE
    end
    e = __fpga_ci_env(ci)
    if e > 0
      return false if __fpga_ld32(e + 8) == __fpga_ld32(__fpga_image(0) + 4) # L:E_STACK L:IMG_c L:CTX_STBASE
      bidx = __fpga_env_bidx(e)
      return false if bidx < 0
      return __fpga_tag(__fpga_ldv(__fpga_ld32(e + 8) + bidx * 16)) > 0 # L:E_STACK L:VALUE
    end
    n = __fpga_and(__fpga_ld8(ci + 0), 15) # L:CI_N
    n = 1 if n == 15
    k = __fpga_and(__fpga_shr(__fpga_ld8(ci + 0), 4), 1) # ci->kw
    __fpga_tag(__fpga_ldv(__fpga_ld32(ci + 16) + (n + k + 1) * 16)) > 0 # L:CI_STACK L:VALUE
  end

  # C: src/kernel.c env_bidx
  def __fpga_env_bidx(e)
    f = __fpga_shr(__fpga_ld32(e + 4), 12) # L:H_FLAGS L:H_FLAGS_SHIFT
    bidx = __fpga_and(__fpga_shr(f, 8), 63) # MRB_ENV_BIDX
    return -1 if bidx >= __fpga_and(f, 255) # MRB_ENV_LEN
    bidx
  end

  # C: src/class.c mrb_obj_clone
  def __fpga_obj_clone(obj)
    return obj unless __fpga_tag(obj) == 7 # L:TAG_OBJ mrb_immediate_p
    __fpga_raise(TypeError, "can't clone singleton class") if __fpga_tt(__fpga_addr(obj)) == 11 # L:TT_SCLASS
    p = __fpga_slot(__fpga_addr(__fpga_obj_class(obj)), __fpga_tt(__fpga_addr(obj)))
    __fpga_st32(p + 0, __fpga_singleton_class_clone(obj)) # L:H_CLASS
    c = __fpga_obj(p)
    __fpga_init_copy(c, obj)
    __fpga_st32(p + 4, __fpga_or(__fpga_ld32(p + 4), __fpga_and(__fpga_ld32(__fpga_addr(obj) + 4), 2048))) # L:H_FLAGS frozen の bit 11
    c
  end

  # 特異クラスを写す (clone)。特異クラスでなければ元のクラス
  # C: src/class.c mrb_singleton_class_clone
  def __fpga_singleton_class_clone(obj)
    klass = __fpga_ld32(__fpga_addr(obj) + 0) # L:H_CLASS
    return klass unless __fpga_tt(klass) == 11 # L:TT_SCLASS
    clone = __fpga_slot(__fpga_image(6), 11) # L:IMG_class_class L:TT_SCLASS
    t = __fpga_tt(__fpga_addr(obj))
    __fpga_st32(clone + 0, __fpga_singleton_class_clone(__fpga_obj(klass))) unless t == 9 || t == 11 # L:H_CLASS L:TT_CLASS L:TT_SCLASS
    __fpga_st32(clone + 8, __fpga_ld32(klass + 8)) # L:C_SUPER
    if __fpga_ld32(klass + 60) > 0 # L:C_IV
      __fpga_iv_copy(__fpga_obj(clone), __fpga_obj(klass))
    end
    __fpga_st32(clone + 28, __fpga_addr(obj)) # L:C_OUTER __attached__
    __fpga_st32(clone + 12, __fpga_mt_copy(__fpga_ld32(klass + 12))) # L:C_MT
    __fpga_st32(clone + 16, __fpga_ld32(klass + 16)) # L:C_ROM
    clone
  end

  # メソッド表を写す (見出しと行を新しく)
  # C: src/class.c mt_copy (D05)
  def __fpga_mt_copy(t)
    n = __fpga_mt_new
    return n if t == 0
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    rows = __fpga_ld32(t + 8) # L:MT_ROWS
    k = 0
    while k < capa
      e = __fpga_ld32(rows + k * 8) # L:MT_ENTRY
      __fpga_mt_set(n, e, __fpga_ld32(rows + k * 8 + 4)) if e < 4294967295 # L:MT_EMPTY
      k += 1
    end
    n
  end

  # クラスの中身を写す (dup / clone。prepend の origin は S5)
  # C: src/class.c copy_class
  def __fpga_copy_class(dst, src)
    dc = __fpga_addr(dst)
    sc = __fpga_addr(src)
    if __fpga_tt(sc) == 15 # L:TT_ICLASS
      __fpga_st32(dc + 12, __fpga_ld32(sc + 12)) # L:C_MT
    else
      __fpga_st32(dc + 12, __fpga_mt_copy(__fpga_ld32(sc + 12))) # L:C_MT
    end
    __fpga_st32(dc + 16, __fpga_ld32(sc + 16)) # L:C_ROM
    __fpga_st32(dc + 8, __fpga_ld32(sc + 8)) # L:C_SUPER
    f = __fpga_ld32(sc + 4) # L:H_FLAGS
    __fpga_st32(dc + 4, f - __fpga_and(f, 2048)) # flags、frozen は 0
  end
end
