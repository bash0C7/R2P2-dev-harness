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
    t = __fpga_alloc(12) # L:MT_HEAD
    rows = __fpga_alloc(capa * 20) # L:IV_ENTRY
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
      rows = __fpga_alloc(capa * 2 * 20)
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
    rows = __fpga_alloc(capa * 20) # L:IV_ENTRY
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
      row = __fpga_const_row(c, sym)
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
    tab = __fpga_image(26) # L:IMG_symtbl
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
    cref = __fpga_addr(__fpga_tclass)
    row = __fpga_const_row(cref, sym)
    if row == 0
      pr = __fpga_ld32(__fpga_proc + 12) # L:P_UPPER
      while row == 0 && pr > 0 && __fpga_ld32(pr + 12) > 0
        tc = __fpga_ld32(pr + 20) # L:P_TCLASS
        row = __fpga_const_row(tc, sym) if tc > 0
        pr = __fpga_ld32(pr + 12)
      end
    end
    row = __fpga_const_walk(cref, sym, true) if row == 0
    return __fpga_setreg(a, __fpga_const_hook(cref, sym)) if row == 0
    __fpga_setreg(a, __fpga_ldv(row + 4))
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
    rows = __fpga_alloc(capa * 20) # L:IV_ENTRY
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
  end

  # OP_SETCONST: 定数 Syms[b] = R[a] (今のクラスに)
  # C: src/vm.c OP_SETCONST
  def __fpga_op_SETCONST(a, b, c)
    v = __fpga_reg(a)
    sym = __fpga_irep_sym(__fpga_irep, b)
    target = __fpga_addr(__fpga_tclass)
    __fpga_tbl_set(__fpga_iv_tbl(target), sym, v) # mrb_const_set (表が無ければ作る)
    __fpga_name_class(v, sym, target)
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
    __fpga_tbl_set(__fpga_iv_tbl(base), sym, v)
    __fpga_name_class(v, sym, base)
  end

  # 名前の無いクラスを定数に入れたら名前を付ける (variable.c の mrb_const_set の中の名前付け)
  # C: src/class.c mrb_class_name_class
  def __fpga_name_class(v, sym, outer)
    return unless __fpga_tag(v) == 7 && __fpga_class_p(__fpga_addr(v))
    c = __fpga_addr(v)
    if __fpga_ld32(c + 24) == 4294967295 # L:C_NAME (名前の無い印)
      __fpga_st32(c + 24, sym)
      __fpga_st32(c + 28, outer) # L:C_OUTER
    end
  end

  # C: src/vm.c OP_OCLASS
  def __fpga_op_OCLASS(a, b, c)
    __fpga_setreg(a, __fpga_core(13)) # L:CORE_OBJECT
  end

  # --- クラスを作る (class.c の mrb_define_class_id と make_metaclass)
  # C: src/gc.c mrb_obj_alloc
  def __fpga_slot(klass, tt)
    o = __fpga_alloc(64) # L:SLOT
    k = 0
    while k < 64
      __fpga_st32(o + k, 0)
      k += 4
    end
    __fpga_st32(o + 0, klass) # L:H_CLASS
    __fpga_st32(o + 4, tt) # L:H_FLAGS
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
    t = __fpga_alloc(12) # L:MT_HEAD
    rows = __fpga_alloc(64)
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
    outer = base.nil? ? __fpga_addr(__fpga_tclass) : __fpga_addr(base)
    row = __fpga_const_row(outer, id)
    if row > 0 # 再オープン
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
    outer = base.nil? ? __fpga_addr(__fpga_tclass) : __fpga_addr(base)
    row = __fpga_const_row(outer, id)
    return __fpga_setreg(a, __fpga_ldv(row + 4)) if row > 0
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
    __fpga_raise(TypeError, "can't define singleton") unless __fpga_tag(obj) == 7 # 即値 (nil / true / false の特異クラスは S5)
    o = __fpga_addr(obj)
    k = __fpga_ld32(o + 0)
    return k if __fpga_tt(k) == 11 && __fpga_ld32(k + 28) == o # L:TT_SCLASS L:C_OUTER
    sc = __fpga_slot(__fpga_addr(__fpga_core(14)), 11)
    __fpga_st32(sc + 8, k)
    __fpga_st32(sc + 12, __fpga_mt_new)
    __fpga_st32(sc + 60, __fpga_tbl_new(8))
    __fpga_st32(sc + 28, o)
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
    sc = __fpga_singleton(__fpga_reg(a))
    pr = __fpga_proc_new(__fpga_ld32(__fpga_ld32(ir + 28) + c * 4), sc, 18688) # L:I_REPS L:PROC_METHOD_FLAGS
    __fpga_st32(pr + 12, __fpga_proc)
    __fpga_define(sc, sym, pr, 0)
    __fpga_setreg(a, __fpga_mkval(4, sym))
  end

  # メソッドを定義する (class.c の mrb_define_method_raw)。vis: 0 public、1 private、2 protected、3 module_function
  # (private のインスタンスメソッドと、特異クラスの public の写し)
  # C: src/class.c mrb_define_method_raw
  def __fpga_define(target, sym, pr, vis)
    if vis == 3
      __fpga_mt_set(__fpga_ld32(target + 12), sym, pr + 1) # L:C_MT L:VIS_PRIVATE
      __fpga_mt_set(__fpga_ld32(__fpga_singleton(__fpga_obj(target)) + 12), sym, pr)
    else
      __fpga_mt_set(__fpga_ld32(target + 12), sym, pr + vis)
    end
    __fpga_mcache_clear
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
    target = __fpga_addr(__fpga_tclass)
    e = __fpga_search(target, __fpga_irep_sym(ir, b))
    __fpga_method_search_error(target, __fpga_irep_sym(ir, b)) if e == 0 # mrb_alias_method の mrb_method_search
    __fpga_mt_set(__fpga_ld32(target + 12), __fpga_irep_sym(ir, a), e)
    __fpga_mcache_clear
  end

  # OP_UNDEF: target_class の Syms[a] を undef (値 0、mruby の MRB_MT_REMOVED)
  # C: src/vm.c OP_UNDEF
  def __fpga_op_UNDEF(a, b, c)
    target = __fpga_addr(__fpga_tclass)
    sym = __fpga_irep_sym(__fpga_irep, a)
    __fpga_name_error(sym, "undefined method '%n' for class '%C'", [__fpga_mkval(4, sym), __fpga_obj(target)]) if __fpga_search(target, sym) == 0 # L:TAG_SYM mrb_undef_method_id
    __fpga_mt_set(__fpga_ld32(target + 12), sym, 0)
    __fpga_mcache_clear
  end

  # OP_SUPER (BB): R[a] = super(R[a+1] ... R[a+n])、b = n | キーワード << 4、ブロックは R[a+n+1]。今のメソッドの見つかったクラス (Proc の target_class) の親から
  # 今のメソッドの名前を引く。target_class が module なら、受け手の祖先の中のその iclass の親から (vm.c の OP_SUPER)
  # C: src/vm.c OP_SUPER
  def __fpga_op_SUPER(a, b, c)
    n = __fpga_and(b, 15)
    __fpga_halt if n == 15 || b > 15 # splat とキーワードの super は後で
    recv = __fpga_reg(0)
    mid = __fpga_mid
    owner = __fpga_ld32(__fpga_proc + 20) # L:P_TCLASS
    start = __fpga_ld32(owner + 8)
    if __fpga_tt(owner) == 10 # L:TT_MODULE
      k = __fpga_addr(__fpga_class_of(recv))
      mt = __fpga_ld32(owner + 12)
      while k > 0 && !(__fpga_tt(k) == 15 && __fpga_ld32(k + 12) == mt) # L:TT_ICLASS
        k = __fpga_ld32(k + 8)
      end
      start = k > 0 ? __fpga_ld32(k + 8) : 0
    end
    e = __fpga_search(start, __fpga_addr(mid))
    args = []
    k = 1
    while k <= n
      args.push(__fpga_reg(a + k))
      k += 1
    end
    blk = __fpga_reg(a + n + 1)
    if e == 0 # vm.c の prepare_missing (method_missing の再定義は S5)
      __fpga_no_method_error(__fpga_addr(mid), args, "no superclass method '%n' for %T", [mid, recv])
    end
    __fpga_setreg(a, __fpga_invoke(recv, e, args, blk, mid))
  end

  # キーワード引数と &nil (vm_op_enter の kdict と MRB_ASPEC_NOBLOCK) は S5
  # C: src/vm.c OP_ENTER
  def __fpga_op_enter_kw(aspec, argc)
    __fpga_halt
  end
end

class BasicObject
  # 引数は取らない (MRB_ARGS_NONE。new に引数を渡して initialize を定義していなければ ArgumentError)
  # C: src/class.c mrb_do_nothing
  def initialize
  end

  # C: src/class.c mrb_f_send
  def __send__(name, *args, &blk)
    __fpga_sendv(self, name, args, blk, true)
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
    __fpga_sendv(self, name, args, blk, true)
  end

  # C: mrbgems/mruby-metaprog/src/metaprog.c mrb_f_public_send
  def public_send(name, *args, &blk)
    __fpga_sendv(self, name, args, blk, false)
  end

  # respond_to? (kernel.c の obj_respond_to): 見つかって、private でない (include_all なら private も)
  # C: src/kernel.c obj_respond_to
  def respond_to?(name, include_all = false)
    e = __fpga_search(__fpga_addr(__fpga_class_of(self)), __fpga_addr(name))
    return false if e == 0
    return true if include_all
    __fpga_and(e, 3) == 1 ? false : true # L:VIS_MASK L:VIS_PRIVATE
  end

  # C: mrbgems/mruby-metaprog/src/metaprog.c mrb_singleton_class
  def singleton_class
    __fpga_obj(__fpga_singleton(self))
  end

  # extend (kernel.c の mrb_obj_extend): 特異クラスに include
  # C: src/kernel.c mrb_obj_extend
  def extend(*mods)
    sc = __fpga_obj(__fpga_singleton(self))
    k = __fpga_alen(mods) - 1
    while k >= 0
      sc.__fpga_include1(__fpga_addr(sc), __fpga_addr(__fpga_aref(mods, k))) # mrb_include_module (helper は Module に置いてある)
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
  # include (class.c の mrb_include_module): self と親の間に iclass を挟む。既にあれば何もしない
  # C: src/class.c mrb_mod_include
  def include(*mods)
    k = __fpga_alen(mods) - 1
    while k >= 0
      __fpga_include1(__fpga_addr(self), __fpga_addr(__fpga_aref(mods, k)))
      k -= 1
    end
    self
  end

  # C: src/class.c include_module_at
  def __fpga_include1(c, m)
    mt = __fpga_ld32(m + 12)
    k = __fpga_ld32(c + 8)
    while k > 0
      return if __fpga_tt(k) == 15 && __fpga_ld32(k + 12) == mt # L:TT_ICLASS
      k = __fpga_ld32(k + 8)
    end
    ic = __fpga_slot(m, 15) # iclass の見出しのクラスは module
    __fpga_st32(ic + 8, __fpga_ld32(c + 8))
    __fpga_st32(ic + 12, mt)
    __fpga_st32(ic + 16, __fpga_ld32(m + 16)) # L:C_ROM
    __fpga_st32(ic + 60, __fpga_iv_tbl(m)) # module の定数を共有する (空なら作ってから、include_class_new)
    __fpga_st32(c + 8, ic)
    __fpga_mcache_clear
  end

  # 可視性 (class.c の mrb_mod_public / private / protected / module_function)。引数が無ければ、呼んだフレームの既定を変える
  # 引数が無い時の __fpga_set_caller_vis は、このメソッドを呼んだフレーム (クラスの本体) に効くので、ここで直接呼ぶ
  # C: src/class.c mrb_mod_public
  def public(*names)
    return __fpga_set_caller_vis(0) if __fpga_alen(names) == 0
    __fpga_visibility(names, 0)
  end

  # C: src/class.c mrb_mod_private
  def private(*names)
    return __fpga_set_caller_vis(1) if __fpga_alen(names) == 0
    __fpga_visibility(names, 1)
  end

  # C: src/class.c mrb_mod_protected
  def protected(*names)
    return __fpga_set_caller_vis(2) if __fpga_alen(names) == 0
    __fpga_visibility(names, 2)
  end

  # C: src/class.c mrb_mod_module_function
  def module_function(*names)
    return __fpga_set_caller_vis(3) if __fpga_alen(names) == 0
    k = 0
    while k < __fpga_alen(names)
      e = __fpga_search(__fpga_addr(self), __fpga_addr(__fpga_aref(names, k)))
      __fpga_mt_set(__fpga_ld32(__fpga_addr(self) + 12), __fpga_addr(__fpga_aref(names, k)), __fpga_and(e, -4) + 1)
      __fpga_mt_set(__fpga_ld32(__fpga_singleton(self) + 12), __fpga_addr(__fpga_aref(names, k)), __fpga_and(e, -4))
      k += 1
    end
    __fpga_mcache_clear
    nil
  end

  # C: src/class.c mrb_mod_visibility
  def __fpga_visibility(names, vis)
    c = __fpga_addr(self)
    k = 0
    while k < __fpga_alen(names)
      e = __fpga_search(c, __fpga_addr(__fpga_aref(names, k)))
      __fpga_method_search_error(c, __fpga_addr(__fpga_aref(names, k))) if e == 0
      __fpga_mt_set(__fpga_ld32(c + 12), __fpga_addr(__fpga_aref(names, k)), __fpga_and(e, -4) + vis)
      k += 1
    end
    __fpga_mcache_clear
    __fpga_alen(names) == 1 ? __fpga_aref(names, 0) : nil
  end

  # attr_reader / attr_writer / attr_accessor (class.c の mrb_mod_attr_reader ...): iv を読み書きする Proc (種類 2 / 3)
  # C: src/class.c mrb_mod_attr_reader
  def attr_reader(*names)
    k = 0
    while k < __fpga_alen(names)
      __fpga_attr(__fpga_aref(names, k), 2, false) # L:PROC_IVGET
      k += 1
    end
    nil
  end

  alias attr attr_reader # class.c の mrb_define_alias_id (attr は attr_reader)

  # C: src/class.c mrb_mod_attr_writer
  def attr_writer(*names)
    k = 0
    while k < __fpga_alen(names)
      __fpga_attr(__fpga_aref(names, k), 3, true) # L:PROC_IVSET
      k += 1
    end
    nil
  end

  # C: src/class.c mrb_mod_attr_accessor
  def attr_accessor(*names)
    k = 0
    while k < __fpga_alen(names)
      __fpga_attr(__fpga_aref(names, k), 2, false) # L:PROC_IVGET
      __fpga_attr(__fpga_aref(names, k), 3, true) # L:PROC_IVSET
      k += 1
    end
    nil
  end

  # C: src/class.c mod_attr_define (D15)
  def __fpga_attr(name, kind, writer)
    s = name.to_s
    iv = __fpga_intern_str("@" + s)
    pr = __fpga_proc_new(iv, __fpga_addr(self), 0)
    __fpga_st32(pr + 24, kind) # L:P_FLAGS
    sym = writer ? __fpga_intern_str(s + "=") : __fpga_addr(name)
    __fpga_define(__fpga_addr(self), sym, pr, 0)
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
  def new(*args, &blk)
    o = allocate
    __fpga_sendv(o, :initialize, args, blk, true) # SSENDB :initialize (新しい物が self、private も)
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
    __fpga_yield_with_class(blk, [self], self, self) unless __fpga_tag(blk) == 0 # L:TAG_NIL
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
