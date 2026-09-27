# firmware: Module と Class のメソッドの残り (mruby の src/class.c の ROM の表、src/vm.c の module_eval / instance_eval、
# src/kernel.c の __case_eqq)。計画 S5-1
class Object
  # 呼んだ側の scope の可視性 (class.c の caller_scope_visibility)。呼んだフレームの target class と self が c の時だけ。
  # C の関数 (firmware の def) から直接呼ぶ: この helper のフレーム、def のフレーム、その呼んだ側 (ec->ci - 1) の順に積まれている
  # その ci の可視性 (ブロックの env の可視性を辿る find_visibility_scope は D19)
  # C: src/class.c caller_scope_visibility (D19)
  def __fpga_caller_scope_vis(c)
    ci = __fpga_ld32(__fpga_image(0) + 12) - 64 * 2 # L:IMG_c L:CTX_CI L:CI_SIZE ec->ci - 1 (helper の分を 1 つ足す)
    return 0 if ci < __fpga_cibase # L:VIS_PUBLIC
    return 0 unless __fpga_ci_tclass(ci) == c
    s = __fpga_ldv(__fpga_ld32(ci + 16)) # L:CI_STACK
    return 0 unless __fpga_tag(s) == 7 && __fpga_addr(s) == c # L:TAG_OBJ
    __fpga_scope_vis(c, ci)
  end

  # C: src/class.c check_visibility_break
  def __fpga_check_visibility_break(p, c, ci, env)
    return true if p == 0 || __fpga_ld32(p + 12) == 0 || __fpga_and(__fpga_ld32(p + 24), 2048) > 0 || __fpga_proc_env(p) == 0 # L:P_UPPER L:P_FLAGS L:PROC_SCOPE MRB_PROC_ENV_P
    if env > 0
      return (__fpga_ld32(__fpga_proc_env(p) + 0) == c) == false || __fpga_and(__fpga_ld32(env + 4), 1073741824) > 0 # L:H_CLASS L:H_FLAGS MRB_ENV_VISIBILITY_BREAK_P (flags の bit 18)
    end
    (__fpga_ci_tclass(ci) == c) == false || __fpga_and(__fpga_ld8(ci + 2), 4) > 0 # L:CI_VIS L:CI_VISIBILITY_BREAK_BIT
  end

  # C: src/class.c find_visibility_env
  def __fpga_find_visibility_env(p, c)
    while true
      env = __fpga_proc_env(p)
      p = __fpga_ld32(p + 12) # L:P_UPPER
      return env if __fpga_check_visibility_break(p, c, 0, env)
    end
  end

  # 可視性を書く所: [ci, 0] か [ci, ci の env] か [0, env] (c が 0 なら ci の target class)
  # C: src/class.c find_visibility_scope
  def __fpga_find_visibility_scope(c, ci)
    p = __fpga_ld32(ci + 8) # L:CI_PROC
    c = __fpga_ci_tclass(ci) if c == 0
    return [ci, __fpga_ci_env(ci)] if __fpga_check_visibility_break(p, c, ci, 0)
    [0, __fpga_find_visibility_env(p, c)]
  end

  # scope の既定の可視性: 0 public、1 private、2 protected、3 module_function (private と MODFUNC)
  # C: src/class.c mrb_define_method_raw
  def __fpga_scope_vis(c, ci)
    s = __fpga_find_visibility_scope(c, ci)
    e = __fpga_aref(s, 1)
    if e > 0
      f = __fpga_ld32(e + 4) # L:H_FLAGS MRB_ENV_VISIBILITY (flags の bit 16〜17) と MRB_ENV_MODFUNC_P (bit 19)
      return __fpga_and(f, 2147483648) > 0 ? 3 : __fpga_and(__fpga_shr(f, 28), 3)
    end
    v = __fpga_ld8(__fpga_aref(s, 0) + 2) # L:CI_VIS
    __fpga_and(v, 8) > 0 ? 3 : __fpga_and(v, 3) # L:CI_MODFUNC_BIT
  end

  # 引数の無い public / private / protected / module_function: 呼んだ側の scope (ci か env) に書く。public でない時は env を作って残す
  # C: src/class.c vis_scope_persist
  def __fpga_set_scope_vis(ci, vis)
    s = __fpga_find_visibility_scope(0, ci)
    sci = __fpga_aref(s, 0)
    e = __fpga_aref(s, 1)
    if e == 0 && vis > 0
      e = __fpga_ci_env(sci) # mrb_vm_ci_env_reify
      if e == 0
        pr = __fpga_ld32(sci + 8) # L:CI_PROC
        e = __fpga_env_new(sci, __fpga_u16(__fpga_ld32(pr + 8) + 0), __fpga_ld32(sci + 16), __fpga_ci_tclass(sci)) # L:P_BODY L:I_NLOCALS L:CI_STACK
        __fpga_st32(sci + 24, e) # L:CI_U
        if __fpga_proc_env(pr) == 0
          __fpga_st32(pr + 16, e) # L:P_ENV
          __fpga_st32(pr + 24, __fpga_or(__fpga_ld32(pr + 24), 1024)) # L:P_FLAGS L:PROC_ENVSET
        end
      end
    end
    v = vis == 3 ? 1 : vis
    m = vis == 3
    if e > 0 # MRB_ENV_SET_VISIBILITY と MRB_ENV_SET_MODFUNC / CLEAR_MODFUNC
      f = __fpga_and(__fpga_ld32(e + 4), 4294967295 - 805306368 - 2147483648) # L:H_FLAGS 可視性の 2 bit と MODFUNC を消す
      __fpga_st32(e + 4, f + __fpga_shl(v, 28) + (m ? 2147483648 : 0)) # L:H_FLAGS
    else # MRB_CI_SET_VISIBILITY と MRB_CI_SET_MODFUNC / CLEAR_MODFUNC
      b = __fpga_and(__fpga_ld8(sci + 2), 255 - 3 - 8) # L:CI_VIS L:CI_MODFUNC_BIT
      __fpga_st8(sci + 2, b + v + (m ? 8 : 0)) # L:CI_VIS L:CI_MODFUNC_BIT
    end
  end

  # C: include/mruby/proc.h MRB_PROC_TARGET_CLASS
  def __fpga_proc_target_class(p)
    e = __fpga_proc_env(p)
    e > 0 ? __fpga_ld32(e + 0) : __fpga_ld32(p + 20) # L:H_CLASS L:P_TCLASS
  end

  # クラス変数の入れ物: upper の鎖の一番近い cref (特異クラスは飛ばす)。無ければ Object (MRB_PROC_GIVEN は D19)
  # C: src/variable.c cv_scope_class (D19)
  def __fpga_cv_scope_class(p)
    while p > 0 && __fpga_and(__fpga_ld32(p + 24), 3) == 0 # L:P_FLAGS MRB_PROC_CFUNC_P
      if __fpga_and(__fpga_ld32(p + 24), 16384) > 0 # L:PROC_CREF
        c = __fpga_proc_target_class(p)
        return c if c > 0 && (__fpga_tt(c) == 11) == false # L:TT_SCLASS
      end
      p = __fpga_ld32(p + 12) # L:P_UPPER
    end
    __fpga_image(5) # L:IMG_object_class
  end

  # C: src/variable.c mrb_mod_cv_get
  def __fpga_cv_get(cls, sym)
    c = cls
    v = nil
    given = false
    while c > 0
      row = __fpga_const_row(c, sym)
      if row > 0
        v = __fpga_ldv(row + 4)
        given = true
      end
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    return v if given
    if __fpga_tt(cls) == 11 # L:TT_SCLASS
      c = __fpga_ld32(cls + 28) # L:C_OUTER __attached__
      if __fpga_tag(__fpga_obj(c)) == 7 && (__fpga_tt(c) == 9 || __fpga_tt(c) == 10) # L:TAG_OBJ L:TT_CLASS L:TT_MODULE
        while c > 0
          row = __fpga_const_row(c, sym)
          if row > 0
            v = __fpga_ldv(row + 4)
            given = true
          end
          c = __fpga_ld32(c + 8) # L:C_SUPER
        end
        return v if given
      end
    end
    __fpga_name_error(sym, "uninitialized class variable %n in %C", [__fpga_mkval(4, sym), __fpga_obj(cls)]) # L:TAG_SYM
  end

  # C: src/variable.c mrb_mod_cv_set
  def __fpga_cv_set(cls, sym, v)
    c = cls
    while c > 0
      row = __fpga_const_row(c, sym)
      if row > 0
        __fpga_check_frozen(c)
        __fpga_stv(row + 4, v)
        return
      end
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    t = __fpga_tt(cls)
    if t == 11 # L:TT_SCLASS
      k = __fpga_ld32(cls + 28) # L:C_OUTER __attached__
      kt = __fpga_tt(k)
      c = (kt == 9 || kt == 10 || kt == 11) ? k : cls # L:TT_CLASS L:TT_MODULE L:TT_SCLASS
    elsif t == 15 # L:TT_ICLASS
      c = __fpga_ld32(cls + 0) # L:H_CLASS
    else
      c = cls
    end
    __fpga_check_frozen(c)
    __fpga_tbl_set(__fpga_iv_tbl(c), sym, v)
  end

  # C: src/vm.c OP_GETCV
  def __fpga_op_GETCV(a, b, c)
    __fpga_setreg(a, __fpga_cv_get(__fpga_cv_scope_class(__fpga_proc), __fpga_irep_sym(__fpga_irep, b)))
  end

  # C: src/vm.c OP_SETCV
  def __fpga_op_SETCV(a, b, c)
    __fpga_cv_set(__fpga_cv_scope_class(__fpga_proc), __fpga_irep_sym(__fpga_irep, b), __fpga_reg(a))
  end

  # C: src/vm.c eval_under
  def __fpga_eval_under(self_, blk, c)
    __fpga_raise(ArgumentError, "no block given") if __fpga_tag(blk) == 0 # L:TAG_NIL check_block
    __fpga_raise(TypeError, "not a block") unless __fpga_tag(blk) == 7 && __fpga_tt(__fpga_addr(blk)) == 16 # L:TAG_OBJ L:TT_PROC
    __fpga_yield_with_class(blk, [self_], self_, c)
  end
end

class BasicObject
  # C: src/vm.c mrb_obj_instance_eval
  def instance_eval(*args, &blk)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    __fpga_raise(NotImplementedError, "instance_eval with string not implemented") if __fpga_alen(args) == 1
    c = __fpga_tag(self) == 7 ? __fpga_singleton(self) : __fpga_addr(__fpga_class_of(self)) # L:TAG_OBJ mrb_singleton_class_ptr (即値は S5)
    __fpga_eval_under(self, blk, c)
  end
end

module Kernel
  # lambda { } (proc.c の proc_lambda): strict でなければ写して STRICT にする
  # C: src/proc.c proc_lambda
  def lambda(&blk)
    __fpga_raise(ArgumentError, "tried to create Proc object without a block") if __fpga_tag(blk) == 0 # L:TAG_NIL
    __fpga_raise(ArgumentError, "not a proc") unless __fpga_tag(blk) == 7 && __fpga_tt(__fpga_addr(blk)) == 16 # L:TAG_OBJ L:TT_PROC check_proc
    b = __fpga_addr(blk)
    return blk if __fpga_and(__fpga_ld32(b + 24), 256) > 0 # L:P_FLAGS L:PROC_STRICT
    p = __fpga_slot(__fpga_ld32(b + 0), 16) # L:H_CLASS L:TT_PROC
    __fpga_st32(p + 24, __fpga_or(__fpga_ld32(b + 24), 256)) # L:P_FLAGS L:PROC_STRICT
    __fpga_st32(p + 8, __fpga_ld32(b + 8)) # L:P_BODY
    __fpga_st32(p + 12, __fpga_ld32(b + 12)) # L:P_UPPER
    __fpga_st32(p + 16, __fpga_ld32(b + 16)) # L:P_ENV
    __fpga_st32(p + 20, __fpga_ld32(b + 20)) # L:P_TCLASS
    __fpga_obj(p)
  end

end

class Module
  # C: src/class.c mrb_mod_ancestors
  def ancestors
    result = []
    c = __fpga_addr(self)
    while c > 0
      if __fpga_tt(c) == 15 # L:TT_ICLASS
        result.__fpga_push1(__fpga_obj(__fpga_ld32(c + 0))) # L:H_CLASS iclass の c
      elsif __fpga_and(__fpga_ld32(c + 4), 2147483648) == 0 # L:H_FLAGS L:CLASS_IS_PREPENDED
        result.__fpga_push1(__fpga_obj(c))
      end
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    result
  end

  # alias_method (class.c の mrb_mod_alias、名前は n)
  # C: src/class.c mrb_mod_alias
  def alias_method(*args)
    __fpga_check_argc(args, 2, 2) # mrb_get_args の nn
    new_name = __fpga_obj_to_sym(__fpga_aref(args, 0))
    old_name = __fpga_obj_to_sym(__fpga_aref(args, 1))
    c = __fpga_addr(self)
    unless new_name == old_name # mrb_alias_method
      e = __fpga_search(c, old_name)
      __fpga_method_search_error(c, old_name) if e == 0
      __fpga_method_raw(c, new_name, e) # MRB_PROC_ALIAS の Proc は S5
    end
    self
  end

  # class_eval / module_eval (ブロックだけ。文字列は NotImplementedError)
  # C: src/vm.c mrb_mod_module_eval
  def module_eval(*args, &blk)
    __fpga_check_argc(args, 0, 1) # mrb_get_args の |S&
    __fpga_raise(NotImplementedError, "module_eval/class_eval with string not implemented") if __fpga_alen(args) == 1
    __fpga_eval_under(self, blk, __fpga_addr(self))
  end

  alias class_eval module_eval # class.c は class_eval と module_eval に同じ関数 mrb_mod_module_eval を置く

  # C: src/class.c mrb_mod_const_get
  def const_get(path)
    if __fpga_tag(path) == 4 # L:TAG_SYM
      __fpga_check_const_name_sym(__fpga_addr(path)) # mrb_const_get_sym
      return __fpga_const_get(self, __fpga_addr(path))
    end
    __fpga_ensure_string_type(path)
    mod = self
    len = __fpga_ld32(__fpga_addr(path) + 8) # L:S_LEN
    ptr = __fpga_ld32(__fpga_addr(path) + 16) # L:S_PTR
    off = 0
    while off < len
      en = __fpga_str_index(path, __fpga_ld32(__fpga_addr("::") + 16), 2, off) # L:S_PTR mrb_str_index_lit
      en = len if en == -1
      id = __fpga_intern(ptr + off, en - off)
      __fpga_check_const_name_sym(id)
      mod = __fpga_const_get(mod, id)
      if en == len
        off = en
      else
        off = en + 2
        __fpga_name_error(id, "wrong constant name '%v'", [path]) if off == len
      end
    end
    mod
  end

  # C: src/class.c mrb_mod_const_set
  def const_set(name, value)
    id = __fpga_obj_to_sym(name)
    __fpga_check_const_name_sym(id)
    __fpga_const_set(__fpga_addr(self), id, value)
    value
  end

  # C: src/class.c mrb_mod_const_missing
  def const_missing(name)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, 0) # L:CI_MID mrb->c->ci->mid = 0
    __fpga_const_missing(__fpga_addr(self), __fpga_obj_to_sym(name))
  end

  # C: src/class.c mrb_mod_method_defined
  def method_defined?(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    id = __fpga_obj_to_sym(__fpga_aref(args, 0))
    inherit = __fpga_alen(args) == 2 ? __fpga_aref(args, 1) : true
    c = __fpga_addr(self)
    e = __fpga_search(c, id) # mrb_mod_method_visibility
    return false if e == 0
    unless inherit
      return false unless __fpga_mt_get(__fpga_ld32(c + 12), id) > 0 || __fpga_mt_get(__fpga_ld32(c + 16), id) > 0 # L:C_MT L:C_ROM found == c
    end
    vis = __fpga_and(e, 3) # L:VIS_MASK
    vis == 0 || vis == 2 # L:VIS_PUBLIC L:VIS_PROTECTED
  end

  # C: src/class.c mrb_mod_undef
  def undef_method(*names)
    c = __fpga_addr(self)
    k = 0
    while k < __fpga_alen(names)
      sym = __fpga_obj_to_sym(__fpga_aref(names, k))
      __fpga_name_error(sym, "undefined method '%n' for class '%C'", [__fpga_mkval(4, sym), self]) if __fpga_search(c, sym) == 0 # L:TAG_SYM mrb_undef_method_id
      __fpga_method_raw(c, sym, 0)
      k += 1
    end
    __fpga_mcache_clear
    nil
  end

  # C: src/class.c mod_define_method
  def define_method(*args, &blk)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    c = __fpga_addr(self)
    vis = __fpga_caller_scope_vis(c)
    mid = __fpga_obj_to_sym(__fpga_aref(args, 0)) # define_method_m の n|o&
    if __fpga_alen(args) == 2
      pr = __fpga_aref(args, 1)
      __fpga_raisef(TypeError, "wrong argument type %T (expected Proc)", [pr]) unless __fpga_tag(pr) == 7 && __fpga_tt(__fpga_addr(pr)) == 16 # L:TAG_OBJ L:TT_PROC
      blk = pr
    end
    __fpga_raise(ArgumentError, "no block given") if __fpga_tag(blk) == 0 # L:TAG_NIL
    p = __fpga_slot(__fpga_image(8), 16) # L:IMG_proc_class L:TT_PROC
    __fpga_proc_copy(p, __fpga_addr(blk))
    __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 256)) # L:P_FLAGS L:PROC_STRICT
    __fpga_method_raw(c, mid, p + (vis == 3 ? 1 : vis)) # L:VIS_PRIVATE modfunc は private
    __fpga_method_added(c, mid)
    if vis == 3 # define_modfunc_copy: 今の名前の値を public で特異クラスへ
      __fpga_method_raw(__fpga_singleton(self), mid, __fpga_and(__fpga_search(c, mid), -4)) # L:VIS_PUBLIC (0)
    end
    __fpga_mkval(4, mid) # L:TAG_SYM
  end

  # C: src/class.c mrb_mod_remove_const
  def remove_const(name)
    id = __fpga_obj_to_sym(name)
    __fpga_check_const_name_sym(id)
    __fpga_check_frozen(__fpga_addr(self)) # mrb_iv_remove は先に凍った物を調べる
    row = __fpga_const_row(__fpga_addr(self), id)
    __fpga_name_error(id, "constant %n not defined", [__fpga_mkval(4, id)]) if row == 0 # L:TAG_SYM
    v = __fpga_ldv(row + 4)
    __fpga_tbl_delete(__fpga_ld32(__fpga_addr(self) + 60), id) # L:C_IV mrb_iv_remove
    v
  end

  # Module.new { } の中身 (class.c の mrb_mod_initialize)
  # C: src/class.c mrb_mod_initialize
  def initialize(&blk)
    __fpga_st32(__fpga_addr(self) + 12, __fpga_mt_new) if __fpga_ld32(__fpga_addr(self) + 12) == 0 # L:C_MT boot_initmod
    __fpga_yield_with_class(blk, [self], self, __fpga_addr(self)) unless __fpga_tag(blk) == 0 # L:TAG_NIL
    self
  end
end

class Class
  # C: src/class.c mrb_class_superclass
  def superclass
    c = __fpga_ld32(__fpga_addr(self) + 8) # L:C_SUPER (prepend の origin は S5)
    c = __fpga_ld32(c + 8) while c > 0 && __fpga_tt(c) == 15 # L:C_SUPER L:TT_ICLASS
    c == 0 ? nil : __fpga_obj(c)
  end
end
