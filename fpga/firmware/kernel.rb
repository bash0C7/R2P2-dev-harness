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
    __fpga_sendv(self, :==, [o], nil, true) ? false : true # neq_iseq の OP_EQ (再定義は送る)
  end

  # C: src/class.c mrb_bob_not
  def !
    self ? false : true
  end

  # C: src/class.c mrb_obj_missing
  def method_missing(*args)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, 0) # L:CI_MID mrb->c->ci->mid = 0
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

  # --- defined? の実行時の helper (コンパイラが呼ぶ)。答えは CRuby の文字列 (凍った literal) か nil
  # C: src/kernel.c mrb_f_defined_method
  def __defined_method?(name)
    sym = __fpga_obj_to_sym(name) # mrb_get_args の n
    rt = __fpga_addr(:respond_to?)
    if __fpga_func_basic_p(self, rt, Kernel) || __fpga_search(__fpga_addr(__fpga_class_of(self)), rt) == 0 # obj_respond_to、mrb_respond_to
      found = __fpga_obj_respond_to_p(self, sym, true)
    else
      found = __fpga_sendv(self, :respond_to?, [__fpga_mkval(4, sym), true], nil, true) ? true : false # L:TAG_SYM mrb_funcall_argv2
    end
    found ? __fpga_obj_freeze("method") : nil
  end

  # C: src/kernel.c mrb_f_defined_ivar
  def __defined_ivar?(name)
    sym = __fpga_obj_to_sym(name)
    return nil unless __fpga_iv_p(self) # mrb_iv_defined の obj_iv_p
    __fpga_const_row(__fpga_addr(self), sym) > 0 ? __fpga_obj_freeze("instance-variable") : nil # mrb_obj_iv_defined
  end

  # 呼んだ側 (ci[-1]) の字句の scope で引く
  # C: src/kernel.c mrb_f_defined_const
  def __defined_const?(name)
    sym = __fpga_obj_to_sym(name)
    ci = __fpga_ld32(__fpga_image(0) + 12) - 64 # L:IMG_c L:CTX_CI L:CI_SIZE ci[-1]
    return nil unless ci >= __fpga_cibase && __fpga_ld32(ci + 8) > 0 # L:CI_PROC
    __fpga_vm_const_get_noraise(ci, sym) > 0 ? __fpga_obj_freeze("constant") : nil # mrb_vm_const_defined_p
  end

  # C: src/kernel.c mrb_f_defined_yield
  def __defined_yield?
    __fpga_block_given ? __fpga_obj_freeze("yield") : nil # mrb_f_block_given_p_m は ci[-1] を見る
  end

  # C: src/kernel.c mrb_f_defined_gvar
  def __defined_gvar?(name)
    sym = __fpga_obj_to_sym(name)
    __fpga_tbl_find(__fpga_image(2), sym) > 0 ? __fpga_obj_freeze("global-variable") : nil # L:IMG_globals mrb_gv_defined
  end

  # C: src/kernel.c mrb_f_defined_cvar
  def __defined_cvar?(name)
    sym = __fpga_obj_to_sym(name)
    ci = __fpga_ld32(__fpga_image(0) + 12) - 64 # L:IMG_c L:CTX_CI L:CI_SIZE ci[-1]
    return nil unless ci >= __fpga_cibase && __fpga_ld32(ci + 8) > 0 # L:CI_PROC
    c = __fpga_cv_scope_class(__fpga_ld32(ci + 8)) # L:CI_PROC mrb_vm_cv_defined_p
    while c > 0 # mrb_mod_cv_defined
      return __fpga_obj_freeze("class variable") if __fpga_const_row(c, sym) > 0
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    nil
  end

  # C: src/kernel.c mrb_f_defined_super
  def __defined_super?
    ci = __fpga_ld32(__fpga_image(0) + 12) - 64 # L:IMG_c L:CTX_CI L:CI_SIZE ci[-1]
    return nil if ci < __fpga_cibase
    mid = __fpga_ld32(ci + 4) # L:CI_MID
    tc = __fpga_ci_tclass(ci)
    if mid > 0 && tc > 0 && __fpga_ld32(tc + 8) > 0 # L:C_SUPER
      return __fpga_obj_freeze("super") if __fpga_search(__fpga_ld32(tc + 8), mid) > 0 # L:C_SUPER
    end
    nil
  end

  # C: src/kernel.c mrb_f_defined_const_path
  def __defined_const_path?(start, path)
    __fpga_ensure_array_type(path) # mrb_get_args の A
    len = __fpga_alen(path)
    return nil if len == 0
    return nil unless __fpga_tag(__fpga_aref(path, 0)) == 4 # L:TAG_SYM
    i = 0
    if __fpga_tag(start) == 0 # L:TAG_NIL
      ci = __fpga_ld32(__fpga_image(0) + 12) - 64 # L:IMG_c L:CTX_CI L:CI_SIZE ci[-1]
      return nil if ci < __fpga_cibase || __fpga_ld32(ci + 8) == 0 # L:CI_PROC
      row = __fpga_vm_const_get_noraise(ci, __fpga_addr(__fpga_aref(path, 0)))
      return nil if row == 0
      outer = __fpga_ldv(row + 4)
      i = 1
    else
      outer = start
    end
    while i < len
      t = __fpga_tag(outer) == 7 ? __fpga_tt(__fpga_addr(outer)) : 0 # L:TAG_OBJ
      return nil unless t == 9 || t == 10 || t == 11 # L:TT_CLASS L:TT_MODULE L:TT_SCLASS
      return nil unless __fpga_tag(__fpga_aref(path, i)) == 4 # L:TAG_SYM
      row = __fpga_const_walk(__fpga_addr(outer), __fpga_addr(__fpga_aref(path, i)), false) # mrb_const_get_noraise (const_get_nohook)
      return nil if row == 0
      outer = __fpga_ldv(row + 4)
      i += 1
    end
    __fpga_obj_freeze("constant")
  end

  # C: src/kernel.c mrb_f_defined_method_on
  def __defined_method_on?(recv, name)
    sym = __fpga_obj_to_sym(name)
    c = __fpga_search_class(__fpga_addr(__fpga_class_of(recv)), sym)
    if c == 0 # MRB_METHOD_UNDEF_P
      rtm = __fpga_addr(:respond_to_missing?)
      if __fpga_func_basic_p(recv, rtm, Kernel) == false && __fpga_search(__fpga_addr(__fpga_class_of(recv)), rtm) > 0 # mrb_false、mrb_respond_to
        return __fpga_obj_freeze("method") if __fpga_sendv(recv, :respond_to_missing?, [__fpga_mkval(4, sym), false], nil, true) # L:TAG_SYM
      end
      return nil
    end
    e = __fpga_search(c, sym)
    return nil if __fpga_and(e, 3) == 1 # L:VIS_MASK L:VIS_PRIVATE
    return nil if __fpga_and(e, 3) == 2 && __fpga_kind_of(self, __fpga_obj(c)) == false # L:VIS_MASK L:VIS_PROTECTED
    __fpga_obj_freeze("method")
  end

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
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, 0) # L:CI_MID mrb->c->ci->mid = 0
    __fpga_check_argc(args, 0, 2) # MRB_ARGS_OPT(2)
    __fpga_f_raise(args)
  end

  # C: src/kernel.c mrb_obj_remove_instance_variable
  def remove_instance_variable(name)
    sym = __fpga_obj_to_sym(name) # mrb_get_args の n
    __fpga_iv_name_sym_check(sym)
    val = __fpga_iv_remove(self, sym)
    __fpga_name_error(sym, "instance variable %n not defined", [__fpga_mkval(4, sym)]) if __fpga_tag(val) == 6 # L:TAG_SYM L:TAG_UNDEF
    val
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

  # 見つかって、呼べる (priv なら private / protected も)。無いか届かなければ respond_to_missing? に聞く (undef は聞かない)。
  # MRB_METHOD_NOTIMPL_P (この機械に無い C の関数) は firmware に無い
  # C: src/kernel.c obj_respond_to_p
  def __fpga_obj_respond_to_p(obj, id, priv)
    c = __fpga_addr(__fpga_class_of(obj))
    e = __fpga_search(c, id)
    return true if e > 0 && (priv || __fpga_and(e, 3) == 0) # L:VIS_MASK MRB_METHOD_PRIVATE_FL|MRB_METHOD_PROTECTED_FL
    rtm = __fpga_addr(:respond_to_missing?)
    if __fpga_func_basic_p(obj, rtm, Kernel) == false && __fpga_search(c, rtm) > 0 # mrb_false、mrb_respond_to
      return __fpga_sendv(obj, :respond_to_missing?, [__fpga_mkval(4, id), priv], nil, true) ? true : false # L:TAG_SYM mrb_funcall_argv2
    end
    false
  end

  # '@' と、数字でない 1 文字目と、英数字と _ (と 0x80 以上) だけ
  # C: src/variable.c mrb_iv_name_sym_p
  def __fpga_iv_name_sym_p(id)
    tab = __fpga_image(1076) # L:IMG_symtbl
    p = __fpga_ld32(tab + id * 8)
    len = __fpga_ld32(tab + id * 8 + 4)
    return false if len < 2
    return false unless __fpga_ld8(p) == 64 # '@'
    return false if __fpga_ld8(p + 1) >= 48 && __fpga_ld8(p + 1) <= 57 # ISDIGIT
    k = 1
    while k < len # mrb_ident_p
      ch = __fpga_ld8(p + k)
      return false unless (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95 || ch >= 128 # identchar
      k += 1
    end
    true
  end

  # C: src/variable.c mrb_iv_name_sym_check
  def __fpga_iv_name_sym_check(id)
    __fpga_name_error(id, "'%n' is not allowed as an instance variable name", [__fpga_mkval(4, id)]) unless __fpga_iv_name_sym_p(id) # L:TAG_SYM
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
    __fpga_st32(dc + 4, __fpga_or(f - __fpga_and(f, 3840), __fpga_and(__fpga_ld32(dc + 4), 1792))) # flags、frozen は 0、gc の色は dc のまま (L:H_FLAGS)
  end
end
