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
    v = __fpga_ld8(ci + 2) # L:CI_VIS
    __fpga_and(v, 8) > 0 ? 3 : __fpga_and(v, 3) # L:CI_MODFUNC_BIT module_function は 3
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
    __fpga_tbl_set(__fpga_iv_tbl(__fpga_addr(self)), id, value) # mrb_const_set
    value
  end

  # C: src/class.c mrb_mod_const_missing
  def const_missing(name)
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
    b = __fpga_addr(blk)
    p = __fpga_slot(__fpga_image(8), 16) # L:IMG_proc_class L:TT_PROC mrb_proc_copy
    __fpga_st32(p + 24, __fpga_or(__fpga_ld32(b + 24), 256)) # L:P_FLAGS L:PROC_STRICT
    __fpga_st32(p + 8, __fpga_ld32(b + 8)) # L:P_BODY
    __fpga_st32(p + 12, __fpga_ld32(b + 12)) # L:P_UPPER
    __fpga_st32(p + 16, __fpga_ld32(b + 16)) # L:P_ENV
    __fpga_st32(p + 20, __fpga_ld32(b + 20)) # L:P_TCLASS
    __fpga_define(c, mid, p, vis == 3 ? 1 : vis) # module_function の写し (define_modfunc_copy) は S5
    __fpga_mkval(4, mid) # L:TAG_SYM
  end

  # C: src/class.c mrb_mod_remove_const
  def remove_const(name)
    id = __fpga_obj_to_sym(name)
    __fpga_check_const_name_sym(id)
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
