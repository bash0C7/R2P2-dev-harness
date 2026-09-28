# firmware: クラス・モジュール・メソッドの定義と探索、定数、インスタンス変数 (mruby の src/class.c、src/variable.c、
# src/vm.c の OP_CLASS OP_MODULE OP_EXEC OP_SCLASS OP_SDEF OP_ALIAS OP_UNDEF OP_SUPER OP_GETCONST ... の遅い道)。
# 定義は実行した時点から効く (mruby と同じ)。コアで走る mruby ソースコード
class Object
  # --- 記憶の上の型
  # C: include/mruby/boxing_no.h mrb_type
  def __fpga_tt(addr)
    __fpga_and(__fpga_ld32(addr + 4), 255) # L:H_FLAGS
  end

  # C: include/mruby/value.h mrb_class_p
  def __fpga_class_p(addr)
    t = __fpga_tt(addr)
    t == 9 || t == 10 || t == 11 # L:TT_CLASS L:TT_MODULE L:TT_SCLASS
  end

  # iv を持てる型 (variable.c の obj_iv_p: OBJECT CLASS MODULE SCLASS HASH CDATA EXCEPTION)
  # C: src/variable.c obj_iv_p
  def __fpga_iv_p(v)
    return false unless __fpga_tag(v) == 7 # L:TAG_OBJ
    t = __fpga_tt(__fpga_addr(v))
    t >= 8 && t <= 14 # L:TT_OBJECT L:TT_EXCEPTION
  end

  # --- iv の表 (layout.rb の IV: 見出し {数, 容量, 行}、行 {シンボル, 値 16 バイト})
  # C: src/variable.c iv_new (D06)
  def __fpga_tbl_new(capa)
    t = __fpga_malloc(12) # L:MT_HEAD
    rows = __fpga_malloc(capa * 20) # L:IV_ENTRY
    k = 0
    while k < capa
      __fpga_st32(rows + k * 20, 4294967295) # L:MT_EMPTY
      k += 1
    end
    __fpga_st32(t + 0, 0) # L:MT_COUNT
    __fpga_st32(t + 4, capa) # L:MT_CAPA
    __fpga_st32(t + 8, rows) # L:MT_ROWS
    t
  end

  # 行の番地 (無ければ 0)
  # C: src/variable.c iv_get (D06)
  def __fpga_tbl_find(t, sym)
    return 0 if t == 0
    capa = __fpga_ld32(t + 4)
    rows = __fpga_ld32(t + 8)
    i = __fpga_and(sym, capa - 1)
    n = 0
    while n < capa
      e = __fpga_ld32(rows + i * 20)
      return 0 if e == 4294967295
      return rows + i * 20 if e == sym
      i = __fpga_and(i + 1, capa - 1)
      n += 1
    end
    0
  end

  # C: src/variable.c iv_put (D06)
  def __fpga_tbl_set(t, sym, v)
    count = __fpga_ld32(t + 0)
    capa = __fpga_ld32(t + 4)
    if (count + 1) * 4 > capa * 3
      old = __fpga_ld32(t + 8)
      rows = __fpga_malloc(capa * 2 * 20)
      k = 0
      while k < capa * 2
        __fpga_st32(rows + k * 20, 4294967295)
        k += 1
      end
      __fpga_st32(t + 8, rows)
      __fpga_st32(t + 4, capa * 2)
      __fpga_st32(t + 0, 0)
      k = 0
      while k < capa
        e = __fpga_ld32(old + k * 20)
        __fpga_tbl_set(t, e, __fpga_ldv(old + k * 20 + 4)) if e < 4294967295
        k += 1
      end
      __fpga_free(old)
      count = __fpga_ld32(t + 0)
      capa *= 2
    end
    rows = __fpga_ld32(t + 8)
    i = __fpga_and(sym, capa - 1)
    while true
      e = __fpga_ld32(rows + i * 20)
      if e == 4294967295 || e == sym
        __fpga_st32(t + 0, count + 1) if e == 4294967295
        __fpga_st32(rows + i * 20, sym)
        __fpga_stv(rows + i * 20 + 4, v)
        return v
      end
      i = __fpga_and(i + 1, capa - 1)
    end
  end

  # オブジェクトの iv の表 (無ければ作る)
  # C: src/variable.c mrb_obj_iv_set (D06)
  def __fpga_iv_tbl(addr)
    t = __fpga_ld32(addr + 60) # L:IV
    if t == 0
      t = __fpga_tbl_new(8)
      __fpga_st32(addr + 60, t)
    end
    t
  end

  # --- インスタンス変数 (variable.c の mrb_iv_get / mrb_iv_set)
  # C: src/variable.c mrb_iv_get
  def __fpga_iv_get(obj, sym)
    return nil unless __fpga_iv_p(obj)
    row = __fpga_tbl_find(__fpga_ld32(__fpga_addr(obj) + 60), sym) # L:IV
    row == 0 ? nil : __fpga_ldv(row + 4)
  end

  # C: src/variable.c mrb_iv_set
  def __fpga_iv_set(obj, sym, v)
    __fpga_raise(ArgumentError, "cannot set instance variable") unless __fpga_iv_p(obj)
    __fpga_check_frozen(__fpga_addr(obj)) # mrb_obj_iv_set
    __fpga_tbl_set(__fpga_iv_tbl(__fpga_addr(obj)), sym, v)
  end

  # 行を消す (開番地法の表なので、消した行を除いて行の並びを作り直す)。消した値か undef
  # C: src/variable.c mrb_iv_remove (D06)
  def __fpga_iv_remove(obj, sym)
    return __fpga_undef unless __fpga_iv_p(obj)
    o = __fpga_addr(obj)
    __fpga_check_frozen(o)
    t = __fpga_ld32(o + 60) # L:IV
    row = __fpga_tbl_find(t, sym)
    return __fpga_undef if row == 0
    val = __fpga_ldv(row + 4)
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    old = __fpga_ld32(t + 8) # L:MT_ROWS
    rows = __fpga_malloc(capa * 20) # L:IV_ENTRY
    k = 0
    while k < capa
      __fpga_st32(rows + k * 20, 4294967295) # L:IV_ENTRY L:MT_EMPTY
      k += 1
    end
    __fpga_st32(t + 8, rows) # L:MT_ROWS
    __fpga_st32(t + 0, 0) # L:MT_COUNT
    k = 0
    while k < capa
      e = __fpga_ld32(old + k * 20) # L:IV_ENTRY
      __fpga_tbl_set(t, e, __fpga_ldv(old + k * 20 + 4)) if e < 4294967295 && (e == sym) == false # L:IV_ENTRY L:MT_EMPTY
      k += 1
    end
    __fpga_free(old)
    val
  end

  # OP_GETIV / OP_SETIV: R[a] = self.@Syms[b] / self.@Syms[b] = R[a]
  # C: src/vm.c OP_GETIV
  def __fpga_op_GETIV(a, b, c)
    __fpga_setreg(a, __fpga_iv_get(__fpga_reg(0), __fpga_irep_sym(__fpga_irep, b)))
  end

  # C: src/vm.c OP_SETIV
  def __fpga_op_SETIV(a, b, c)
    __fpga_iv_set(__fpga_reg(0), __fpga_irep_sym(__fpga_irep, b), __fpga_reg(a))
  end

  # attr_reader / attr_writer の Proc の罠 (回路が呼ぶ)
  # C: src/class.c mrb_attr_reader (D15)
  def __fpga_op_ivget(obj, name)
    __fpga_iv_get(obj, __fpga_addr(name))
  end

  # C: src/class.c mrb_attr_writer (D15)
  def __fpga_op_ivset(obj, name, v)
    __fpga_iv_set(obj, __fpga_addr(name), v)
  end

  # --- 定数 (variable.c の mrb_vm_const_get / const_get_nohook)
  # C: src/variable.c const_get
  def __fpga_const_row(c, sym)
    __fpga_tbl_find(__fpga_ld32(c + 60), sym) # L:C_IV
  end

  # base から親へ (skip は base 自身を飛ばす)。見つからなければ 0 (行の番地)
  # C: src/variable.c mrb_vm_const_get
  def __fpga_const_walk(base, sym, skip)
    obj = __fpga_addr(__fpga_core(13)) # L:CORE_OBJECT
    c = skip ? __fpga_ld32(base + 8) : base # L:C_SUPER
    while c > 0
      row = __fpga_and(__fpga_ld32(c + 4), 2147483648) > 0 ? 0 : __fpga_const_row(c, sym) # L:H_FLAGS L:CLASS_IS_PREPENDED
      return row if row > 0
      c = __fpga_ld32(c + 8)
      return 0 if c == obj && skip == false
    end
    if skip && __fpga_tt(base) == 10 # L:TT_MODULE: module なら Object からもう一度
      c = obj
      while c > 0
        row = __fpga_const_row(c, sym)
        return row if row > 0
        c = __fpga_ld32(c + 8)
      end
    end
    0
  end

  # const_defined_0: klass から (recurse なら親へ) 定数の表を見る。exclude でない module は Object も
  # C: src/variable.c const_defined_0
  def __fpga_const_defined(klass, id, exclude, recurse)
    tmp = klass
    mod_retry = false
    while true
      while tmp > 0
        return true if __fpga_const_row(tmp, id) > 0
        break if recurse == false && (klass == __fpga_image(5)) == false # L:IMG_object_class
        tmp = __fpga_ld32(tmp + 8) # L:C_SUPER
      end
      return false if exclude || mod_retry || (__fpga_tt(klass) == 10) == false # L:TT_MODULE
      mod_retry = true
      tmp = __fpga_image(5) # L:IMG_object_class
    end
  end

  # C: src/etc.c mrb_obj_to_sym
  def __fpga_obj_to_sym(name)
    return __fpga_addr(name) if __fpga_tag(name) == 4 # L:TAG_SYM
    return __fpga_intern_str(name) if __fpga_tag(name) == 7 && __fpga_tt(__fpga_addr(name)) == 18 # L:TAG_OBJ L:TT_STRING
    __fpga_raisef(TypeError, "%!v is not a symbol nor a string", [name])
  end

  # 大文字で始まり、後ろは英数字と _ (と 0x80 以上) だけ (mrb_ident_p)
  # C: src/class.c mrb_const_name_p
  def __fpga_const_name_p(id)
    tab = __fpga_image(1076) # L:IMG_symtbl
    p = __fpga_ld32(tab + id * 8)
    len = __fpga_ld32(tab + id * 8 + 4)
    return false unless len > 0 && __fpga_ld8(p) >= 65 && __fpga_ld8(p) <= 90 # ISUPPER
    k = 1
    while k < len
      ch = __fpga_ld8(p + k)
      ok = (ch >= 48 && ch <= 57) || (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95 || ch >= 128
      return false unless ok
      k += 1
    end
    true
  end

  # C: src/class.c check_const_name_sym
  def __fpga_check_const_name_sym(id)
    __fpga_name_error(id, "wrong constant name %n", [__fpga_mkval(4, id)]) unless __fpga_const_name_p(id) # L:TAG_SYM
  end

  # C: src/class.c mrb_const_missing
  def __fpga_const_missing(c, sym)
    unless __fpga_real(c) == __fpga_image(5) # L:IMG_object_class
      __fpga_name_error(sym, "uninitialized constant %v::%n", [__fpga_obj(c), __fpga_mkval(4, sym)]) # L:TAG_SYM
    end
    __fpga_name_error(sym, "uninitialized constant %n", [__fpga_mkval(4, sym)]) # L:TAG_SYM
  end

  # OP_GETCONST: R[a] = 定数 Syms[b]。今のクラス → 字句の外側 (upper の Proc の target_class、一番外は除く) → 祖先 → module なら Object
  # C: src/vm.c OP_GETCONST
  def __fpga_op_GETCONST(a, b, c)
    sym = __fpga_irep_sym(__fpga_irep, b)
    row = __fpga_vm_const_get_noraise(__fpga_ci, sym) # mrb_vm_const_get
    if row == 0
      c = __fpga_vm_const_base(__fpga_ci)
      c = __fpga_const_sclass_base(c) if __fpga_tt(c) == 11 # L:TT_SCLASS
      return __fpga_setreg(a, __fpga_const_hook(c, sym)) # const_get の const_missing
    end
    __fpga_setreg(a, __fpga_ldv(row + 4))
  end

  # ci の字句の scope で定数を引く (cref、upper の鎖の字句の scope、cref の祖先)。定数の表の行か 0 (hook は呼ばない)。
  # base は hook を送る先 (特異クラスなら付いているクラス)
  # C: src/variable.c mrb_vm_const_get_noraise
  def __fpga_vm_const_get_noraise(ci, sym)
    c = __fpga_vm_const_base(ci)
    row = __fpga_const_row(c, sym)
    return row if row > 0
    pr = __fpga_ld32(__fpga_ld32(ci + 8) + 12) # L:CI_PROC L:P_UPPER
    while pr > 0 && __fpga_ld32(pr + 12) > 0 # L:P_UPPER
      if __fpga_lexical_scope_p(pr)
        row = __fpga_const_row(__fpga_proc_class(pr), sym)
        return row if row > 0
      end
      pr = __fpga_ld32(pr + 12) # L:P_UPPER
    end
    if __fpga_tt(c) == 11 # L:TT_SCLASS
      row = __fpga_const_walk(c, sym, true)
      return row if row > 0
      c = __fpga_const_sclass_base(c)
    end
    __fpga_const_walk(c, sym, true) # const_get_nohook
  end

  # 引く所の cref (無ければ Object)
  # C: src/variable.c mrb_vm_const_get
  def __fpga_vm_const_base(ci)
    c = __fpga_cref_class(ci)
    c == 0 ? __fpga_image(5) : c # L:IMG_object_class
  end

  # 特異クラスは付いている物をたどり、class か module に着けばそれ
  # C: src/variable.c mrb_vm_const_get
  def __fpga_const_sclass_base(c)
    c2 = c
    while c2 > 0 && __fpga_tt(c2) == 11 # L:TT_SCLASS
      c2 = __fpga_ld32(c2 + 28) # L:C_OUTER __attached__
      c2 = 0 unless __fpga_tt(c2) == 9 || __fpga_tt(c2) == 10 || __fpga_tt(c2) == 11 # L:TT_CLASS L:TT_MODULE L:TT_SCLASS mrb_class_ptr
    end
    (c2 > 0 && (__fpga_tt(c2) == 9 || __fpga_tt(c2) == 10)) ? c2 : c # L:TT_CLASS L:TT_MODULE
  end

  # C: src/variable.c proc_class
  def __fpga_proc_class(p)
    c = __fpga_proc_target_class(p)
    c == 0 ? __fpga_image(5) : c # L:IMG_object_class
  end

  # クラスや メソッドの本体 (MRB_PROC_SCOPE) は字句の scope、ブロックは入れ物が upper と違う時だけ。与えられた (GIVEN) Proc は違う
  # C: src/variable.c lexical_scope_p
  def __fpga_lexical_scope_p(p)
    f = __fpga_ld32(p + 24) # L:P_FLAGS
    return false if __fpga_and(f, 32768) > 0 && __fpga_and(f, 3) == 0 # MRB_PROC_GIVEN_P
    return true if __fpga_and(f, 2048) > 0 # L:PROC_SCOPE
    (__fpga_proc_class(p) == __fpga_proc_class(__fpga_ld32(p + 12))) == false # L:P_UPPER
  end

  # 見つからない定数: const_missing が Module のもの (mrb_mod_const_missing) なら NameError、ほかは const_missing を送る
  # C: src/variable.c const_get
  def __fpga_const_hook(base, sym)
    mod = __fpga_obj(base)
    return __fpga_const_missing(base, sym) if __fpga_func_basic_p(mod, __fpga_addr(:const_missing), Module)
    mod.const_missing(__fpga_mkval(4, sym)) # L:TAG_SYM
  end

  # C: src/variable.c mrb_const_get
  def __fpga_const_get(mod, sym)
    row = __fpga_const_walk(__fpga_addr(mod), sym, false) # const_get_nohook
    return __fpga_const_hook(__fpga_addr(mod), sym) if row == 0
    __fpga_ldv(row + 4)
  end

  # 表から sym の行を消す (開番地法なので、残りを入れ直す)
  # C: src/variable.c iv_del (D06)
  def __fpga_tbl_delete(t, sym)
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    old = __fpga_ld32(t + 8) # L:MT_ROWS
    rows = __fpga_malloc(capa * 20) # L:IV_ENTRY
    k = 0
    while k < capa
      __fpga_st32(rows + k * 20, 4294967295) # L:MT_EMPTY
      k += 1
    end
    __fpga_st32(t + 8, rows) # L:MT_ROWS
    __fpga_st32(t + 0, 0) # L:MT_COUNT
    k = 0
    while k < capa
      e = __fpga_ld32(old + k * 20)
      __fpga_tbl_set(t, e, __fpga_ldv(old + k * 20 + 4)) if e < 4294967295 && (e == sym) == false
      k += 1
    end
    __fpga_free(old)
  end

  # OP_SETCONST: 定数 Syms[b] = R[a] (今のクラスに)
  # C: src/vm.c OP_SETCONST
  def __fpga_op_SETCONST(a, b, c)
    v = __fpga_reg(a)
    sym = __fpga_irep_sym(__fpga_irep, b)
    target = __fpga_cref_class(__fpga_ci)
    target = __fpga_image(5) if target == 0 # L:IMG_object_class
    __fpga_const_set(target, sym, v)
  end

  # OP_GETMCNST: R[a] = R[a]::Syms[b]
  # C: src/vm.c OP_GETMCNST
  def __fpga_op_GETMCNST(a, b, c)
    base = __fpga_addr(__fpga_reg(a))
    sym = __fpga_irep_sym(__fpga_irep, b)
    row = __fpga_const_walk(base, sym, false)
    return __fpga_setreg(a, __fpga_const_missing(base, sym)) if row == 0
    __fpga_setreg(a, __fpga_ldv(row + 4))
  end

  # OP_SETMCNST: R[a+1]::Syms[b] = R[a]
  # C: src/vm.c OP_SETMCNST
  def __fpga_op_SETMCNST(a, b, c)
    v = __fpga_reg(a)
    base = __fpga_addr(__fpga_reg(a + 1))
    sym = __fpga_irep_sym(__fpga_irep, b)
    __fpga_const_set(base, sym, v)
  end

  # C: src/variable.c mrb_const_set
  def __fpga_const_set(mod, sym, v)
    __fpga_name_class(v, sym, mod) # mrb_type(v) が CLASS か MODULE
    __fpga_check_frozen(mod) # mrb_obj_iv_set
    __fpga_tbl_set(__fpga_iv_tbl(mod), sym, v)
    __fpga_sendv(__fpga_obj(mod), :const_added, [__fpga_mkval(4, sym)], nil, true) # L:TAG_SYM mrb_funcall_argv
  end

  # 名前の無いクラス / モジュールを定数に置いた時に名前を付ける (C_NAME と C_OUTER、D04)。名前の無い outer の中では
  # outer も覚え (mruby の __outer__)、道は outer の名前 (無名なら "#<Module:0x..>") から作る
  # C: src/class.c mrb_class_name_class (D04)
  def __fpga_name_class(v, sym, outer)
    return unless __fpga_tag(v) == 7 && (__fpga_tt(__fpga_addr(v)) == 9 || __fpga_tt(__fpga_addr(v)) == 10) # L:TAG_OBJ L:TT_CLASS L:TT_MODULE
    c = __fpga_addr(v)
    return unless __fpga_ld32(c + 24) == 0 # L:C_NAME __classname__ がある
    __fpga_st32(c + 24, sym) # L:C_NAME
    __fpga_st32(c + 28, outer == __fpga_image(5) ? 0 : outer) # L:C_OUTER L:IMG_object_class
  end

  # C: src/vm.c OP_OCLASS
  def __fpga_op_OCLASS(a, b, c)
    __fpga_setreg(a, __fpga_core(13)) # L:CORE_OBJECT
  end

  # --- クラスを作る (class.c の mrb_define_class_id と make_metaclass)
  # 枠を作る。tt の語は見出しの語の tt と flags (色は mrb_obj_alloc_core が付ける)。回路の速い道 (primitive) か、落ちたら gc.rb
  # C: src/gc.c mrb_obj_alloc_core
  def __fpga_slot(klass, tt)
    o = __fpga_obj_alloc(__fpga_and(tt, 255), klass)
    __fpga_st32(o + 4, __fpga_or(__fpga_ld32(o + 4), __fpga_and(tt, -256))) if tt > 255 # L:H_FLAGS
    o
  end

  # インスタンスを作る: tt はクラスの MRB_INSTANCE_TT (0 は OBJECT)。特異クラスと、即値の型 (CPTR 以下) は TypeError
  # C: src/class.c mrb_instance_alloc
  def __fpga_instance_alloc(cv)
    c = __fpga_addr(cv)
    __fpga_raise(TypeError, "can't create instance of singleton class") if __fpga_tt(c) == 11 # L:TT_SCLASS
    tt = __fpga_and(__fpga_shr(__fpga_ld32(c + 4), 12), 31) # L:H_FLAGS L:H_FLAGS_SHIFT L:INSTANCE_TT_MASK
    nil_or_false = c == __fpga_image(17) || c == __fpga_image(16) # L:IMG_nil_class L:IMG_false_class
    tt = 8 if tt == 0 && nil_or_false == false # L:TT_OBJECT
    __fpga_raisef(TypeError, "can't create instance of %v", [cv]) if tt <= 7 # L:TT_CPTR
    __fpga_obj(__fpga_slot(c, tt))
  end

  # C: src/class.c mt_new (D05)
  def __fpga_mt_new
    t = __fpga_malloc(12) # L:MT_HEAD
    rows = __fpga_malloc(64)
    k = 0
    while k < 8
      __fpga_st32(rows + k * 8, 4294967295) # L:MT_EMPTY
      k += 1
    end
    __fpga_st32(t + 0, 0)
    __fpga_st32(t + 4, 8)
    __fpga_st32(t + 8, rows)
    t
  end

  # C: src/class.c boot_defclass
  def __fpga_class_new(sup, name, outer)
    meta_sup = sup > 0 ? __fpga_ld32(sup + 0) : __fpga_addr(__fpga_core(14)) # L:CORE_CLASS 親のメタクラス
    meta = __fpga_slot(__fpga_addr(__fpga_core(14)), 11) # L:TT_SCLASS
    __fpga_st32(meta + 8, meta_sup) # L:C_SUPER
    __fpga_st32(meta + 12, __fpga_mt_new) # L:C_MT
    __fpga_st32(meta + 60, __fpga_tbl_new(8)) # L:C_IV
    itt = sup > 0 ? __fpga_and(__fpga_shr(__fpga_ld32(sup + 4), 12), 31) : 0 # L:H_FLAGS L:H_FLAGS_SHIFT L:INSTANCE_TT_MASK 親の MRB_INSTANCE_TT
    c = __fpga_slot(meta, __fpga_or(9, __fpga_shl(itt, 12))) # L:TT_CLASS L:H_FLAGS_SHIFT
    if sup > 0
      __fpga_st32(c + 4, __fpga_or(__fpga_ld32(c + 4), __fpga_and(__fpga_ld32(sup + 4), 268435456))) # L:H_FLAGS L:CLASS_EQ_DEFINED
      __fpga_st32(sup + 4, __fpga_or(__fpga_ld32(sup + 4), 536870912)) # L:H_FLAGS L:CLASS_IS_INHERITED mrb_class_inherited
    end
    __fpga_st32(meta + 28, c) # L:C_OUTER (付いているクラス)
    __fpga_st32(c + 8, sup)
    __fpga_st32(c + 12, __fpga_mt_new)
    __fpga_st32(c + 60, __fpga_tbl_new(8))
    __fpga_st32(c + 24, name) # L:C_NAME
    __fpga_st32(c + 28, outer)
    c
  end

  # C: src/class.c mrb_module_new
  def __fpga_module_new(name, outer)
    m = __fpga_slot(__fpga_addr(__fpga_core(15)), 10) # L:CORE_MODULE L:TT_MODULE
    __fpga_st32(m + 12, __fpga_mt_new)
    __fpga_st32(m + 60, __fpga_tbl_new(8))
    __fpga_st32(m + 24, name)
    __fpga_st32(m + 28, outer)
    m
  end

  # 本当の親 (iclass と特異クラスを飛ばす、class.c の mrb_class_real)
  # C: src/class.c mrb_class_real
  def __fpga_real(c)
    while c > 0 && (__fpga_tt(c) == 15 || __fpga_tt(c) == 11) # L:TT_ICLASS L:TT_SCLASS
      c = __fpga_ld32(c + 8)
    end
    c
  end

  # OP_CLASS: R[a] = newclass(R[a] (入れ物、nil は今のクラス), Syms[b], R[a+1] (親、nil は Object))
  # C: src/vm.c OP_CLASS
  def __fpga_op_CLASS(a, b, c)
    base = __fpga_reg(a)
    sup = __fpga_reg(a + 1)
    id = __fpga_irep_sym(__fpga_irep, b)
    if __fpga_tag(base) == 0 # L:TAG_NIL
      base = __fpga_cref_class(__fpga_ci)
      base = __fpga_obj(base == 0 ? __fpga_image(5) : base) # L:IMG_object_class
    end
    # mrb_vm_define_class
    unless __fpga_tag(sup) == 0 # L:TAG_NIL
      __fpga_raisef(TypeError, "superclass must be a Class (%!v given)", [sup]) unless __fpga_tag(sup) == 7 && __fpga_tt(__fpga_addr(sup)) == 9 # L:TAG_OBJ L:TT_CLASS mrb_class_p
    end
    __fpga_check_if_class_or_module(base)
    outer = __fpga_addr(base)
    row = __fpga_const_row(outer, id)
    if row > 0 # mrb_obj_iv_defined: 再オープン
      v = __fpga_ldv(row + 4)
      __fpga_raisef(TypeError, "%!v is not a class", [v]) unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 9 # L:TAG_OBJ L:TT_CLASS
      if __fpga_tag(sup) == 7 && (__fpga_real(__fpga_ld32(__fpga_addr(v) + 8)) == __fpga_addr(sup)) == false # L:TAG_OBJ L:C_SUPER
        __fpga_raisef(TypeError, "superclass mismatch for %v", [v])
      end
      return __fpga_setreg(a, v)
    end
    s = sup.nil? ? __fpga_addr(__fpga_core(13)) : __fpga_addr(sup)
    cls = __fpga_obj(__fpga_class_new(s, id, outer))
    __fpga_tbl_set(__fpga_iv_tbl(outer), id, cls)
    __fpga_sendv(__fpga_obj(s), :inherited, [cls], nil, true) # class.c の mrb_class_inherited (mrb_funcall_argv、可視性を見ない)
    __fpga_setreg(a, cls)
  end

  # OP_MODULE: R[a] = newmodule(R[a], Syms[b])
  # C: src/vm.c OP_MODULE
  def __fpga_op_MODULE(a, b, c)
    base = __fpga_reg(a)
    id = __fpga_irep_sym(__fpga_irep, b)
    if __fpga_tag(base) == 0 # L:TAG_NIL
      base = __fpga_cref_class(__fpga_ci)
      base = __fpga_obj(base == 0 ? __fpga_image(5) : base) # L:IMG_object_class
    end
    __fpga_check_if_class_or_module(base) # mrb_vm_define_module
    outer = __fpga_addr(base)
    row = __fpga_const_row(outer, id)
    if row > 0
      old = __fpga_ldv(row + 4)
      __fpga_raisef(TypeError, "%!v is not a module", [old]) unless __fpga_tag(old) == 7 && __fpga_tt(__fpga_addr(old)) == 10 # L:TAG_OBJ L:TT_MODULE mrb_module_p
      return __fpga_setreg(a, old)
    end
    m = __fpga_obj(__fpga_module_new(id, outer))
    __fpga_tbl_set(__fpga_iv_tbl(outer), id, m)
    __fpga_setreg(a, m)
  end

  # OP_EXEC: R[a] = R[a] を self と target_class にして Irep[b] を実行 (クラスの本体)
  # C: src/vm.c OP_EXEC
  def __fpga_op_EXEC(a, b, c)
    cls = __fpga_reg(a)
    pr = __fpga_proc_new(__fpga_ld32(__fpga_ld32(__fpga_irep + 28) + b * 4), __fpga_addr(cls), 18432) # L:I_REPS (OP_EXEC: MRB_PROC_SCOPE | MRB_PROC_CREF)
    __fpga_st32(pr + 12, __fpga_proc) # L:P_UPPER
    __fpga_setreg(a, __fpga_invoke(cls, pr, nil, nil, nil))
  end

  # 特異クラス (class.c の mrb_singleton_class): オブジェクトとその class の間に SCLASS を挟む
  # C: src/class.c prepare_singleton_class
  def __fpga_singleton(obj)
    t = __fpga_tag(obj) # mrb_singleton_class_ptr の即値
    return __fpga_image(17) if t == 0 # L:TAG_NIL L:IMG_nil_class
    return __fpga_image(16) if t == 1 # L:TAG_FALSE L:IMG_false_class
    return __fpga_image(15) if t == 2 # L:TAG_TRUE L:IMG_true_class
    __fpga_raise(TypeError, "can't define singleton") unless t == 7 # L:TAG_OBJ mrb_singleton_class
    o = __fpga_addr(obj)
    k = __fpga_ld32(o + 0)
    return k if __fpga_tt(k) == 11 && __fpga_ld32(k + 28) == o # L:TT_SCLASS L:C_OUTER
    sc = __fpga_slot(__fpga_addr(__fpga_core(14)), 11)
    __fpga_st32(sc + 8, k)
    __fpga_st32(sc + 12, __fpga_mt_new)
    __fpga_st32(sc + 60, __fpga_tbl_new(8))
    __fpga_st32(sc + 28, o)
    __fpga_st32(sc + 4, __fpga_or(__fpga_ld32(sc + 4), __fpga_and(__fpga_ld32(o + 4), 2048))) # L:H_FLAGS L:H_FROZEN prepare_singleton_class の sc->frozen = o->frozen
    __fpga_st32(sc + 4, __fpga_or(__fpga_ld32(sc + 4), 536870912 + __fpga_and(__fpga_ld32(k + 4), 268435456))) # L:H_FLAGS L:CLASS_IS_INHERITED L:CLASS_EQ_DEFINED
    __fpga_st32(o + 0, sc)
    __fpga_mcache_clear
    sc
  end

  # OP_SCLASS: R[a] = R[a].singleton_class
  # C: src/vm.c OP_SCLASS
  def __fpga_op_SCLASS(a, b, c)
    __fpga_setreg(a, __fpga_obj(__fpga_singleton(__fpga_reg(a))))
  end

  # OP_SDEF: R[a].singleton_class に Syms[b] を Irep[c] で定義し、R[a] = :名前
  # C: src/vm.c OP_SDEF
  def __fpga_op_SDEF(a, b, c)
    ir = __fpga_irep
    sym = __fpga_irep_sym(ir, b)
    __fpga_vm_define_method(__fpga_singleton(__fpga_reg(a)), ir, b, c, 0) # MRB_METHOD_PUBLIC_FL
    __fpga_setreg(a, __fpga_mkval(4, sym))
  end

  # メソッドを定義する (class.c の mrb_define_method_raw)。vis: 0 public、1 private、2 protected、3 module_function
  # (private のインスタンスメソッドと、特異クラスの public の写し)
  # C: src/class.c mrb_define_method_raw
  def __fpga_define(target, sym, pr, vis)
    if vis == 3
      __fpga_method_raw(target, sym, pr + 1) # L:VIS_PRIVATE
      __fpga_method_raw(__fpga_singleton(__fpga_obj(target)), sym, pr)
    else
      __fpga_method_raw(target, sym, pr + vis)
    end
  end

  # c (prepend されていれば origin) の表に sym = val (メソッド表の値 Proc | 可視性、undef は 0) を置く。表が無ければ作る
  # --- 演算子の再定義の印 (class.c の bop_*、mrb_state.bop_redefined)。回路の Integer の演算と == の近道は、この bit が立っていれば送る
  # C: src/class.c bop_class
  def __fpga_bop_class(slot)
    return __fpga_image(14) if slot < 9 # L:IMG_integer_class L:BOP_COUNT
    return __fpga_image(18) if slot == 18 # L:IMG_symbol_class L:BOP_SYMBOL_EQ_SLOT
    __fpga_image(13) # L:IMG_float_class
  end

  # C: src/class.c bop_mid
  def __fpga_bop_mid(slot)
    return __fpga_addr(:==) if slot == 18 # L:BOP_SYMBOL_EQ_SLOT
    k = slot < 9 ? slot : slot - 9 # L:BOP_COUNT slot % MRB_BOP_COUNT
    return __fpga_addr(:+) if k == 0
    return __fpga_addr(:-) if k == 1
    return __fpga_addr(:*) if k == 2
    return __fpga_addr(:/) if k == 3
    return __fpga_addr(:==) if k == 4
    return __fpga_addr(:<) if k == 5
    return __fpga_addr(:<=) if k == 6
    return __fpga_addr(:>) if k == 7
    __fpga_addr(:>=)
  end

  # 今の値が C の関数 (像の中の firmware の def) なら記録して bit を下ろす
  # C: src/class.c bop_arm
  def __fpga_bop_arm(slot)
    __fpga_st32(1095 * 4, __fpga_or(__fpga_ld32(45 * 4), __fpga_shl(1, slot))) # L:IMG_bop_redefined L:WORD
    e = __fpga_search(__fpga_bop_class(slot), __fpga_bop_mid(slot))
    return if e == 0 || __fpga_and(e, -4) >= __fpga_image(1085) # L:IMG_heap_start MRB_METHOD_UNDEF_P、MRB_METHOD_FUNC_P でない
    __fpga_st32(__fpga_image(1096) + slot * 4, e) # L:IMG_bop_builtin L:WORD
    __fpga_st32(1095 * 4, __fpga_and(__fpga_ld32(45 * 4), 4294967295 - __fpga_shl(1, slot))) # L:IMG_bop_redefined L:WORD
  end

  # C: src/class.c bop_refresh
  def __fpga_bop_refresh(slot)
    b = __fpga_ld32(__fpga_image(1096) + slot * 4) # L:IMG_bop_builtin L:WORD
    return if b == 0
    bit = __fpga_shl(1, slot)
    w = __fpga_ld32(1095 * 4) # L:IMG_bop_redefined L:WORD
    w = __fpga_search(__fpga_bop_class(slot), __fpga_bop_mid(slot)) == b ? __fpga_and(w, 4294967295 - bit) : __fpga_or(w, bit)
    __fpga_st32(1095 * 4, w) # L:IMG_bop_redefined L:WORD
  end

  # C: src/class.c mrb_builtin_op_init
  def __fpga_builtin_op_init
    tbl = __fpga_malloc(19 * 4) # L:WORD MRB_BOP_SLOT_COUNT (C は mrb_state の中の並び、D18)
    k = 0
    while k < 19
      __fpga_st32(tbl + k * 4, 0) # L:WORD
      k += 1
    end
    __fpga_st32(1096 * 4, tbl) # L:IMG_bop_builtin L:WORD
    k = 0
    while k < 19
      __fpga_bop_arm(k)
      k += 1
    end
  end

  # 起動の途中 (bop_builtin が 0) は何もしない。mid が 0 なら全部の slot
  # C: src/class.c mrb_builtin_op_update
  def __fpga_builtin_op_update(mid)
    return if __fpga_image(1096) == 0 # L:IMG_bop_builtin mrb->bootstrapping
    k = 0
    while k < 19
      __fpga_bop_refresh(k) if mid == 0 || mid == __fpga_bop_mid(k)
      k += 1
    end
  end

  # heap の走査の callback: まだ印の無いクラスで、祖先 (iclass は module) のどれかに印があれば付ける
  # C: src/class.c eq_defined_walk
  def __fpga_eq_defined_walk(obj, data)
    t = __fpga_tt(obj)
    if t == 9 || t == 11 || t == 10 # L:TT_CLASS L:TT_SCLASS L:TT_MODULE
      unless __fpga_and(__fpga_ld32(obj + 4), 268435456) > 0 # L:H_FLAGS L:CLASS_EQ_DEFINED
        s = __fpga_ld32(obj + 8) # L:C_SUPER
        while s > 0
          r = __fpga_tt(s) == 15 ? __fpga_ld32(s + 0) : s # L:TT_ICLASS L:H_CLASS s->c
          if __fpga_and(__fpga_ld32(r + 4), 268435456) > 0 # L:H_FLAGS L:CLASS_EQ_DEFINED
            __fpga_st32(obj + 4, __fpga_or(__fpga_ld32(obj + 4), 268435456)) # L:H_FLAGS L:CLASS_EQ_DEFINED
            break
          end
          s = __fpga_ld32(s + 8) # L:C_SUPER
        end
      end
    end
    0 # MRB_EACH_OBJ_OK
  end

  # c が自分の == を持った: 印を付け、子のクラス (と include した物) へは heap を走査して付ける。nil / true / false は bop の bit へ
  # C: src/class.c eq_defined_mark
  def __fpga_eq_defined_mark(c)
    return if __fpga_and(__fpga_ld32(c + 4), 268435456) > 0 # L:H_FLAGS L:CLASS_EQ_DEFINED
    __fpga_st32(c + 4, __fpga_or(__fpga_ld32(c + 4), 268435456)) # L:H_FLAGS L:CLASS_EQ_DEFINED
    if __fpga_and(__fpga_ld32(c + 4), 536870912) > 0 || __fpga_tt(c) == 10 # L:H_FLAGS L:CLASS_IS_INHERITED L:TT_MODULE
      __fpga_gc_each_live_object(:__fpga_eq_defined_walk, 0)
    end
    if __fpga_and(__fpga_or(__fpga_or(__fpga_ld32(__fpga_image(17) + 4), __fpga_ld32(__fpga_image(15) + 4)), __fpga_ld32(__fpga_image(16) + 4)), 268435456) > 0 # L:IMG_nil_class L:IMG_true_class L:IMG_false_class L:H_FLAGS L:CLASS_EQ_DEFINED
      __fpga_st32(1095 * 4, __fpga_or(__fpga_ld32(1095 * 4), 524288)) # L:IMG_bop_redefined L:WORD L:BOP_NIL_TRUE_FALSE_EQ
    end
  end

  # C: src/class.c mrb_define_method_raw
  def __fpga_method_raw(c, sym, val)
    named = c
    if val > 0 && (sym == __fpga_addr(:initialize) || sym == __fpga_addr(:initialize_copy) || sym == __fpga_addr(:respond_to_missing?))
      val = __fpga_and(val, -4) + 1 # L:VIS_PRIVATE いつも private (~3 で可視性の bit を消す)
    end
    c = __fpga_class_origin(c)
    __fpga_check_frozen(named) # mt_writable
    __fpga_st32(c + 12, __fpga_mt_new) if __fpga_ld32(c + 12) == 0 # L:C_MT mt_writable の mt_new
    __fpga_mt_set(__fpga_ld32(c + 12), sym, val) # L:C_MT
    __fpga_mcache_clear_id(sym) # mc_clear_by_id
    __fpga_builtin_op_update(sym)
    __fpga_eq_defined_mark(named) if sym == __fpga_addr(:==) && __fpga_image(1096) > 0 # L:IMG_bop_builtin mrb->bootstrapping でない
  end

  # TDEF / SDEF: Irep[c] のメソッドの Proc を作って tc に Syms[b] で置き、method_added を呼ぶ
  # C: src/vm.c vm_define_method
  def __fpga_vm_define_method(tc, ir, b, c, vis)
    p = __fpga_method_proc_new(__fpga_ci, __fpga_ld32(__fpga_ld32(ir + 28) + c * 4)) # L:I_REPS
    __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 256)) # L:P_FLAGS L:PROC_STRICT
    mid = __fpga_irep_sym(ir, b)
    __fpga_define(tc, mid, p, vis)
    __fpga_method_added(tc, mid)
    mid
  end

  # C: src/class.c mrb_method_added
  def __fpga_method_added(c, mid)
    if __fpga_tt(c) == 11 # L:TT_SCLASS
      recv = __fpga_obj(__fpga_ld32(c + 28)) # L:C_OUTER __attached__
      __fpga_sendv(recv, :singleton_method_added, [__fpga_mkval(4, mid)], nil, true) unless __fpga_func_basic_p(recv, __fpga_addr(:singleton_method_added), BasicObject) # L:TAG_SYM mrb_do_nothing
    else
      recv = __fpga_obj(c)
      __fpga_sendv(recv, :method_added, [__fpga_mkval(4, mid)], nil, true) unless __fpga_func_basic_p(recv, __fpga_addr(:method_added), Module) # L:TAG_SYM mrb_do_nothing
    end
  end

  # 探索 (罠と同じ順、mrb_method_search_vm)。メソッド表の値か 0
  # C: src/class.c mrb_method_search_vm (D05)
  def __fpga_search(c, sym)
    while c > 0
      e = __fpga_mt_get(__fpga_ld32(c + 12), sym) # L:C_MT
      return e if e >= 0
      e = __fpga_mt_get(__fpga_ld32(c + 16), sym) # L:C_ROM
      return e if e >= 0
      c = __fpga_ld32(c + 8)
    end
    0
  end

  # 探索して、見つかったクラス (mrb_vm_find_method の *cp) を返す。無いか undef なら 0
  # C: src/class.c mrb_vm_find_method (D05)
  def __fpga_search_class(c, sym)
    while c > 0
      e = __fpga_mt_get(__fpga_ld32(c + 12), sym) # L:C_MT
      e = __fpga_mt_get(__fpga_ld32(c + 16), sym) if e < 0 # L:C_ROM
      return e == 0 ? 0 : c if e >= 0
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    0
  end

  # メソッド表を引く: 値 (undef は 0) か、無ければ -1
  # C: src/class.c mt_get (D05)
  def __fpga_mt_get(t, sym)
    return -1 if t == 0
    capa = __fpga_ld32(t + 4)
    rows = __fpga_ld32(t + 8)
    i = __fpga_and(sym, capa - 1)
    n = 0
    while n < capa
      e = __fpga_ld32(rows + i * 8)
      return -1 if e == 4294967295
      return __fpga_ld32(rows + i * 8 + 4) if e == sym
      i = __fpga_and(i + 1, capa - 1)
      n += 1
    end
    -1
  end

  # OP_ALIAS: target_class で Syms[a] を Syms[b] の別名に (class.c の mrb_alias_method)
  # C: src/vm.c OP_ALIAS
  def __fpga_op_ALIAS(a, b, c)
    ir = __fpga_irep
    target = __fpga_check_target_class
    e = __fpga_search(target, __fpga_irep_sym(ir, b))
    __fpga_method_search_error(target, __fpga_irep_sym(ir, b)) if e == 0 # mrb_alias_method の mrb_method_search
    __fpga_method_raw(target, __fpga_irep_sym(ir, a), e)
  end

  # OP_UNDEF: target_class の Syms[a] を undef (値 0、mruby の MRB_MT_REMOVED)
  # C: src/vm.c OP_UNDEF
  def __fpga_op_UNDEF(a, b, c)
    target = __fpga_check_target_class
    sym = __fpga_irep_sym(__fpga_irep, a)
    __fpga_name_error(sym, "undefined method '%n' for class '%C'", [__fpga_mkval(4, sym), __fpga_obj(target)]) if __fpga_search(target, sym) == 0 # L:TAG_SYM mrb_undef_method_id
    __fpga_method_raw(target, sym, 0)
  end

  # OP_SUPER (BB): R[a] = super(R[a+1] ... R[a+n])、b = n | キーワード << 4、ブロックは R[a+n+1]。今のメソッドの見つかったクラス (Proc の target_class) の親から
  # 今のメソッドの名前を引く。target_class が module なら、受け手の祖先の中のその iclass の親から (vm.c の OP_SUPER)
  # C: src/vm.c OP_SUPER
  def __fpga_op_SUPER(a, b, c)
    n = __fpga_and(b, 15)
    nk = __fpga_shr(b, 4)
    recv = __fpga_reg(0)
    mid = __fpga_mid
    target = __fpga_ci_tclass(__fpga_ci) # CI_TARGET_CLASS(ci): メソッドが見つかったクラス (module のメソッドなら iclass)
    __fpga_raise(NoMethodError, "super called outside of method") if __fpga_addr(mid) == 0 || target == 0
    if __fpga_and(__fpga_ld32(target + 4), 2147483648) > 0 || __fpga_tt(target) == 10 || __fpga_kind_of(recv, __fpga_obj(target)) == false # L:H_FLAGS L:CLASS_IS_PREPENDED L:TT_MODULE
      __fpga_raise(TypeError, "self has wrong type to call super in this context")
    end

    kidx = a + (n == 15 ? 1 : n) + 1
    kdict = nil
    if nk == 15
      kdict = __fpga_ensure_hash_type(__fpga_reg(kidx))
    elsif nk > 0 # hash_new_from_regs
      kdict = __fpga_hash_new_capa(nk)
      i = 0
      while i < nk
        __fpga_hash_set(kdict, __fpga_reg(kidx + i * 2), __fpga_reg(kidx + i * 2 + 1))
        i += 1
      end
    end
    blk = __fpga_reg(kidx + (nk == 15 ? 1 : nk * 2)) # mrb_bidx(n, nk)
    if n == 15
      args = __fpga_reg(a + 1)
    else
      args = []
      k = 1
      while k <= n
        args.__fpga_push1(__fpga_reg(a + k))
        k += 1
      end
    end
    found = __fpga_search_class(__fpga_ld32(target + 8), __fpga_addr(mid)) # L:C_SUPER CI_TARGET_CLASS(ci - 1)->super から
    e = found == 0 ? 0 : __fpga_search(found, __fpga_addr(mid))
    if e == 0 # vm.c の prepare_missing (super): method_missing が BasicObject のもの (mrb_obj_missing) なら NoMethodError
      args = __fpga_ary_subseq(args, 0, __fpga_alen(args)) # mrb_args_pack_positional
      if __fpga_func_basic_p(recv, __fpga_addr(:method_missing), BasicObject)
        __fpga_no_method_error(__fpga_addr(mid), args, "no superclass method '%n' for %T", [mid, recv])
      end
      found = __fpga_search_class(__fpga_addr(__fpga_class_of(recv)), __fpga_addr(:method_missing)) # ci->u.target_class = mrb_class(recv)
      e = __fpga_search(found, __fpga_addr(:method_missing))
      __fpga_ary_unshift1(args, mid)
      mid = :method_missing # ci->mid = missing
    end
    __fpga_setreg(a, __fpga_invoke(recv, e, args, blk, mid, __fpga_obj(found), kdict)) # 呼ばれるフレームの target_class は見つかったクラス
  end

end

class BasicObject
  # C: src/class.c mrb_do_nothing
  def singleton_method_added(m)
  end

  # 引数は取らない (MRB_ARGS_NONE。new に引数を渡して initialize を定義していなければ ArgumentError)
  # C: src/class.c mrb_do_nothing
  def initialize
  end

  # C: src/class.c mrb_f_send
  def __send__(name, *args, &blk)
    __fpga_sendv(self, __fpga_mkval(4, __fpga_obj_to_sym(name)), args, blk, true) # L:TAG_SYM send_method の mrb_obj_to_sym
  end
end

module Kernel
  # nil? (kernel.c の mrb_false、NilClass は mrb_true)
  # C: src/kernel.c mrb_false
  def nil?
    false
  end

  # C: src/kernel.c mrb_obj_class_m
  def class
    __fpga_obj(__fpga_real(__fpga_addr(__fpga_class_of(self))))
  end

  # C: mrbgems/mruby-metaprog/src/metaprog.c mrb_f_send
  def send(name, *args, &blk)
    __fpga_sendv(self, __fpga_mkval(4, __fpga_obj_to_sym(name)), args, blk, true) # L:TAG_SYM send_method の mrb_obj_to_sym
  end

  # C: mrbgems/mruby-metaprog/src/metaprog.c mrb_f_public_send
  def public_send(name, *args, &blk)
    __fpga_sendv(self, __fpga_mkval(4, __fpga_obj_to_sym(name)), args, blk, false) # L:TAG_SYM send_method の mrb_obj_to_sym
  end

  # C: src/kernel.c obj_respond_to
  def respond_to?(name, include_all = false)
    __fpga_obj_respond_to_p(self, __fpga_obj_to_sym(name), include_all ? true : false) # mrb_get_args の n|b
  end

  # C: src/kernel.c mrb_false
  def respond_to_missing?(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    false
  end

  # C: mrbgems/mruby-metaprog/src/metaprog.c mrb_singleton_class
  def singleton_class
    __fpga_obj(__fpga_singleton(self))
  end

  # C: src/class.c mrb_obj_extend
  def extend(*mods)
    cc = __fpga_singleton(self)
    k = __fpga_alen(mods) - 1
    while k >= 0
      m = __fpga_aref(mods, k)
      __fpga_check_type_module(m)
      __fpga_include_module(cc, __fpga_addr(m))
      m.extended(self) unless __fpga_func_basic_p(m, __fpga_addr(:extended), Module) # mrb_do_nothing
      k -= 1
    end
    self
  end

  # C: src/kernel.c mrb_obj_is_kind_of_m
  def is_a?(c)
    __fpga_kind_of(self, c)
  end

  alias kind_of? is_a? # kernel.c は is_a? と kind_of? に同じ関数 mrb_obj_is_kind_of_m を置く
end

class Module
  # C: src/class.c mrb_mod_include
  def include(*mods)
    k = __fpga_alen(mods) - 1
    while k >= 0
      m = __fpga_aref(mods, k)
      __fpga_check_type_module(m)
      __fpga_include_module(__fpga_addr(self), __fpga_addr(m))
      m.included(self) unless __fpga_func_basic_p(m, __fpga_addr(:included), Module) # mrb_do_nothing
      k -= 1
    end
    self
  end

  # C: src/class.c mrb_mod_prepend
  def prepend(*mods)
    k = __fpga_alen(mods) - 1
    while k >= 0
      m = __fpga_aref(mods, k)
      __fpga_check_type_module(m)
      __fpga_prepend_module(__fpga_addr(self), __fpga_addr(m))
      m.prepended(self) unless __fpga_func_basic_p(m, __fpga_addr(:prepended), Module) # mrb_do_nothing
      k -= 1
    end
    self
  end

  # clone (特異クラスも写す) して凍っていない物に
  # C: src/class.c mrb_mod_dup
  def dup
    mod = __fpga_obj_clone(self)
    __fpga_st32(__fpga_addr(mod) + 4, __fpga_and(__fpga_ld32(__fpga_addr(mod) + 4), 4294967295 - 2048)) # L:H_FLAGS L:H_FROZEN
    mod
  end

  # C: src/class.c mrb_do_nothing
  def included(m)
  end

  # C: src/class.c mrb_do_nothing
  def method_added(m)
  end

  # C: src/class.c mrb_do_nothing
  def const_added(m)
  end

  # C: src/class.c mrb_do_nothing
  def prepended(m)
  end

  # C: src/class.c mrb_do_nothing
  def extended(m)
  end

end

class Object
  # C: src/class.c check_if_class_or_module
  def __fpga_check_if_class_or_module(obj)
    t = __fpga_tag(obj) == 7 ? __fpga_tt(__fpga_addr(obj)) : 0 # L:TAG_OBJ
    __fpga_raisef(TypeError, "%!v is not a class/module", [obj]) unless t == 9 || t == 10 || t == 11 # L:TT_CLASS L:TT_MODULE L:TT_SCLASS class_ptr_p
  end

  # mrb_check_type(x, MRB_TT_SYMBOL)。シンボルの番号を返す
  # C: src/object.c mrb_check_type
  def __fpga_check_type_symbol(x)
    return __fpga_addr(x) if __fpga_tag(x) == 4 # L:TAG_SYM
    t = __fpga_tag(x)
    if t == 0 # L:TAG_NIL
      ename = "nil"
    elsif t == 3 # L:TAG_INT
      ename = "Integer"
    elsif t < 7 # L:TAG_OBJ mrb_immediate_p
      ename = __fpga_obj_as_string(x)
    else
      ename = __fpga_mod_to_s(__fpga_obj_class(x)) # mrb_obj_classname
    end
    __fpga_raisef(TypeError, "wrong argument type %S (expected Symbol)", [ename])
  end

  # mrb_check_type(x, MRB_TT_MODULE)
  # C: src/object.c mrb_check_type
  def __fpga_check_type_module(x)
    return if __fpga_tag(x) == 7 && __fpga_tt(__fpga_addr(x)) == 10 # L:TAG_OBJ L:TT_MODULE
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
    __fpga_raisef(TypeError, "wrong argument type %S (expected Module)", [ename])
  end

  # MRB_CLASS_ORIGIN: prepend された class / module は、表を持つ origin の iclass へ
  # C: include/mruby/class.h MRB_CLASS_ORIGIN
  def __fpga_class_origin(c)
    if __fpga_and(__fpga_ld32(c + 4), 2147483648) > 0 # L:H_FLAGS L:CLASS_IS_PREPENDED
      c = __fpga_ld32(c + 8) # L:C_SUPER
      while __fpga_and(__fpga_ld32(c + 4), 1073741824) == 0 # L:H_FLAGS L:CLASS_IS_ORIGIN
        c = __fpga_ld32(c + 8) # L:C_SUPER
      end
    end
    c
  end

  # C: src/class.c include_class_new
  def __fpga_include_class_new(m, sup)
    m = __fpga_ld32(m + 0) if __fpga_tt(m) == 15 # L:H_CLASS L:TT_ICLASS m->c
    m = __fpga_class_origin(m)
    c = __fpga_tt(m) == 15 ? __fpga_ld32(m + 0) : m # L:TT_ICLASS L:H_CLASS
    ic = __fpga_slot(c, 15) # L:TT_ICLASS MRB_OBJ_ALLOC(ICLASS, class_class) の後 ic->c = m
    __fpga_st32(ic + 12, __fpga_ld32(m + 12)) # L:C_MT
    __fpga_st32(ic + 16, __fpga_ld32(m + 16)) # L:C_ROM (D05 の ROM の表も同じ物を指す)
    __fpga_st32(ic + 60, __fpga_iv_tbl(c)) # L:IV module の定数を共有する (iv_tbl、空なら作ってから)
    __fpga_st32(ic + 8, sup) # L:C_SUPER
    ic
  end

  # 0 は入れた、-1 は輪 (c の表と m の表が同じ)
  # C: src/class.c include_module_at
  def __fpga_include_module_at(c, ins_pos, m, search_super)
    m0 = m
    klass_mt = __fpga_ld32(__fpga_class_origin(c) + 12) # L:C_MT
    while m > 0
      p = __fpga_ld32(c + 8) # L:C_SUPER
      original_seen = false
      superclass_seen = false
      original_seen = true if c == ins_pos
      skip = __fpga_and(__fpga_ld32(m + 4), 2147483648) > 0 # L:H_FLAGS L:CLASS_IS_PREPENDED
      unless skip
        return -1 if klass_mt > 0 && klass_mt == __fpga_ld32(m + 12) # L:C_MT
        while p > 0
          original_seen = true if c == p
          if __fpga_tt(p) == 15 # L:TT_ICLASS
            if __fpga_ld32(p + 12) == __fpga_ld32(m + 12) # L:C_MT
              ins_pos = p if superclass_seen == false && original_seen # move insert point
              skip = true
              break
            end
          elsif __fpga_tt(p) == 9 # L:TT_CLASS
            break if search_super == 0
            superclass_seen = true
          end
          p = __fpga_ld32(p + 8) # L:C_SUPER
        end
      end
      unless skip
        ic = __fpga_include_class_new(m, __fpga_ld32(ins_pos + 8)) # L:C_SUPER
        __fpga_st32(m + 4, __fpga_or(__fpga_ld32(m + 4), 536870912)) # L:H_FLAGS L:CLASS_IS_INHERITED
        __fpga_st32(ins_pos + 8, ic) # L:C_SUPER
        ins_pos = ic
      end
      m = __fpga_ld32(m + 8) # L:C_SUPER
    end
    __fpga_mcache_clear
    __fpga_builtin_op_update(0)
    __fpga_eq_defined_mark(c) if __fpga_and(__fpga_ld32(m0 + 4), 268435456) > 0 && __fpga_image(1096) > 0 # L:H_FLAGS L:CLASS_EQ_DEFINED L:IMG_bop_builtin
    0
  end

  # fix_include_module (既に include された module へ伝える) は mrb_objspace_each_objects が要るので写していない (D60)
  # C: src/class.c mrb_include_module
  def __fpga_include_module(c, m)
    __fpga_check_frozen(c)
    __fpga_raise(ArgumentError, "cyclic include detected") if __fpga_include_module_at(c, __fpga_class_origin(c), m, 1) < 0
  end

  # C: src/class.c mrb_prepend_module
  def __fpga_prepend_module(c, m)
    __fpga_check_frozen(c)
    if __fpga_and(__fpga_ld32(c + 4), 2147483648) == 0 # L:H_FLAGS L:CLASS_IS_PREPENDED
      origin = __fpga_slot(c, 15) # L:TT_ICLASS MRB_OBJ_ALLOC(ICLASS, c)
      __fpga_st32(origin + 4, __fpga_or(__fpga_ld32(origin + 4), 1073741824 + 536870912)) # L:H_FLAGS L:CLASS_IS_ORIGIN L:CLASS_IS_INHERITED
      __fpga_st32(origin + 8, __fpga_ld32(c + 8)) # L:C_SUPER
      __fpga_st32(c + 8, origin) # L:C_SUPER
      __fpga_st32(origin + 12, __fpga_ld32(c + 12)) # L:C_MT
      __fpga_st32(c + 12, 0) # L:C_MT
      __fpga_st32(origin + 16, __fpga_ld32(c + 16)) # L:C_ROM (D05 の ROM の表も origin へ)
      __fpga_st32(c + 16, 0) # L:C_ROM
      __fpga_st32(c + 4, __fpga_or(__fpga_ld32(c + 4), 2147483648)) # L:H_FLAGS L:CLASS_IS_PREPENDED
    end
    __fpga_raise(ArgumentError, "cyclic prepend detected") if __fpga_include_module_at(c, c, m, 0) < 0
  end
end

class Module

  # 可視性 (class.c の mrb_mod_public / private / protected / module_function)。引数が無ければ、呼んだフレームの既定を変える
  # (ブロックの env に書く find_visibility_scope と vis_scope_persist は D19)。
  # 引数が無い時は、このメソッドを呼んだフレーム (ec->ci - 1) の scope に書く (find_visibility_scope、vis_scope_persist)
  # C: src/class.c mrb_mod_public
  def public(*names)
    __fpga_alen(names) == 0 ? __fpga_set_scope_vis(__fpga_ld32(__fpga_image(0) + 12) - 64, 0) : __fpga_mod_visibility(names, 0) # L:VIS_PUBLIC
    self
  end

  # C: src/class.c mrb_mod_private
  def private(*names)
    __fpga_alen(names) == 0 ? __fpga_set_scope_vis(__fpga_ld32(__fpga_image(0) + 12) - 64, 1) : __fpga_mod_visibility(names, 1) # L:VIS_PRIVATE
    self
  end

  # C: src/class.c mrb_mod_protected
  def protected(*names)
    __fpga_alen(names) == 0 ? __fpga_set_scope_vis(__fpga_ld32(__fpga_image(0) + 12) - 64, 2) : __fpga_mod_visibility(names, 2) # L:VIS_PROTECTED
    self
  end

  # 引数が無ければ、後の def を private のインスタンスメソッドと public の特異メソッドにする (MRB_CI_SET_MODFUNC)
  # C: src/class.c mrb_mod_module_function
  def module_function(*names)
    __fpga_check_type_module(self)
    if __fpga_alen(names) == 0
      __fpga_set_scope_vis(__fpga_ld32(__fpga_image(0) + 12) - 64, 3) # L:IMG_c L:CTX_CI L:CI_SIZE 呼んだ側 (ec->ci - 1) を private と MODFUNC に
      return self
    end
    ai = __fpga_gc_arena_save
    k = 0
    while k < __fpga_alen(names)
      mid = __fpga_check_type_symbol(__fpga_aref(names, k))
      e = __fpga_search(__fpga_addr(self), mid)
      __fpga_method_search_error(__fpga_addr(self), mid) if e == 0 # mrb_method_search
      __fpga_method_raw(__fpga_singleton(self), mid, __fpga_and(e, -4)) # VIS_PUBLIC (0)
      __fpga_method_raw(__fpga_addr(self), mid, __fpga_and(e, -4) + 1) # L:VIS_PRIVATE
      __fpga_gc_arena_restore(ai)
      k += 1
    end
    self
  end

  # 名前ごとに、探したメソッドを可視性を変えて自分 (prepend されていれば origin) の表に写す。1 つの配列は名前の並び
  # C: src/class.c mrb_mod_visibility
  def __fpga_mod_visibility(names, vis)
    c = __fpga_addr(self)
    __fpga_check_frozen(c) # mt_writable
    t = __fpga_class_origin(c)
    __fpga_st32(t + 12, __fpga_mt_new) if __fpga_ld32(t + 12) == 0 # L:C_MT mt_writable
    names = __fpga_aref(names, 0) if __fpga_alen(names) == 1 && __fpga_tag(__fpga_aref(names, 0)) == 7 && __fpga_tt(__fpga_addr(__fpga_aref(names, 0))) == 17 # L:TAG_OBJ L:TT_ARRAY
    k = 0
    while k < __fpga_alen(names)
      mid = __fpga_check_type_symbol(__fpga_aref(names, k))
      e = __fpga_search(c, mid)
      __fpga_method_search_error(c, mid) if e == 0 # mrb_method_search
      __fpga_mt_set(__fpga_ld32(t + 12), mid, __fpga_and(e, -4) + vis) # L:C_MT mt_put
      __fpga_builtin_op_update(mid)
      k += 1
    end
    __fpga_mcache_clear
  end

  # C: src/class.c mrb_mod_attr_reader
  def attr_reader(*names)
    __fpga_attr_define(names, true, false, __fpga_caller_scope_vis(__fpga_addr(self)))
  end

  alias attr attr_reader # class.c の mrb_define_alias_id (attr は attr_reader)

  # C: src/class.c mrb_mod_attr_writer
  def attr_writer(*names)
    __fpga_attr_define(names, false, true, __fpga_caller_scope_vis(__fpga_addr(self)))
  end

  # C: src/class.c mrb_mod_attr_accessor
  def attr_accessor(*names)
    __fpga_attr_define(names, true, true, __fpga_caller_scope_vis(__fpga_addr(self)))
  end

  # 名前ごとに reader (と writer) を定義し、その名前の配列を返す。Proc は iv を読み書きする種類 2 / 3 (D15)。
  # module_function の scope では private で、特異クラスの写しは作らない
  # C: src/class.c mod_attr_define (D15)
  def __fpga_attr_define(names, reader, writer, vis)
    c = __fpga_addr(self)
    vis = 1 if vis == 3 # L:VIS_PRIVATE modfunc
    result = []
    ai = __fpga_gc_arena_save
    i = 0
    while i < __fpga_alen(names)
      sym = __fpga_obj_to_sym(__fpga_aref(names, i)) # to_sym
      ivar = __fpga_prepare_name(sym, "@", "") # prepare_ivar_name
      __fpga_iv_name_sym_check(ivar)
      w = 0
      while w < 2
        if w == 1 ? writer : reader
          mid = w == 1 ? __fpga_prepare_name(sym, "", "=") : sym # prepare_writer_name
          pr = __fpga_proc_new(ivar, c, w == 1 ? 3 : 2) # L:PROC_IVSET L:PROC_IVGET mrb_proc_new_cfunc_with_env
          __fpga_method_raw(c, mid, pr + vis)
          result.__fpga_push1(__fpga_mkval(4, mid)) # L:TAG_SYM
        end
        w += 1
      end
      __fpga_gc_arena_restore(ai)
      i += 1
    end
    result
  end

  # prefix と名前と suffix をつないだシンボル
  # C: src/class.c prepare_name_common
  def __fpga_prepare_name(sym, prefix, suffix)
    s = __fpga_str_new(0, 0)
    __fpga_str_cat_str(s, prefix)
    __fpga_str_cat_str(s, __fpga_sym_str(sym))
    __fpga_str_cat_str(s, suffix)
    __fpga_intern_str(s)
  end
end

class Module
  # C: src/class.c mrb_mod_const_defined
  def const_defined?(name, inherit = true)
    id = __fpga_obj_to_sym(name)
    __fpga_check_const_name_sym(id)
    __fpga_const_defined(__fpga_addr(self), id, true, inherit ? true : false) # mrb_const_defined / mrb_const_defined_at
  end
end

class Class
  # new (class.c の mrb_instance_new): allocate して initialize を送る (private でも呼べる)
  # C: src/class.c new_iseq
  def new(*args, **kw, &blk)
    o = allocate
    __fpga_sendv(o, :initialize, args, blk, true, kw) # SSENDB :initialize n=*|nk=* (新しい物が self、private も)
    o
  end

  # Class.new(super = Object) { } (class.c の mrb_class_new_class): 名前の無いクラスを作り、inherited と initialize
  # C: src/class.c mrb_class_new_class
  def self.new(*args, &blk)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    sup = __fpga_alen(args) == 0 ? Object : __fpga_aref(args, 0)
    __fpga_raisef(TypeError, "%v is not class/module", [sup]) unless __fpga_tag(sup) == 7 && __fpga_class_p(__fpga_addr(sup)) # L:TAG_OBJ mrb_get_args の C
    s = __fpga_addr(sup)
    __fpga_raisef(TypeError, "superclass must be a Class (%C given)", [sup]) unless __fpga_tt(s) == 9 # L:TT_CLASS mrb_check_inheritable
    __fpga_raise(TypeError, "can't make subclass of Class") if s == __fpga_image(6) # L:IMG_class_class
    c = __fpga_obj(__fpga_class_new(s, 0, 0)) # mrb_class_new
    __fpga_sendv(sup, :inherited, [c], nil, true) # mrb_class_inherited
    __fpga_sendv(c, :initialize, args, blk, true)
    c
  end

  # Class#initialize: ブロックがあれば、クラスを self と定義の入れ物にして呼ぶ
  # C: src/class.c mrb_class_initialize
  def initialize(*args, &blk)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    __fpga_yield_with_class(blk, [self], self, __fpga_addr(self)) unless __fpga_tag(blk) == 0 # L:TAG_NIL
    self
  end

  # C: src/class.c mrb_instance_alloc
  def allocate
    __fpga_instance_alloc(self)
  end

  # Class#inherited (private、何もしない)
  # C: src/class.c mrb_do_nothing
  def inherited(klass)
  end
end
