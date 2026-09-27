# firmware: 回路が持たない命令のうち、配列の多重代入、シンボル、メソッドの定義の遅い道 (mruby の src/vm.c の CASE、計画 S4-4)。
# a, b, c は命令の operand、__fpga_reg / __fpga_setreg は罠を起こしたフレームのレジスタ
class Object
  # OP_AREF: R[a] = R[b][c] (Array でなければ c == 0 の時だけ R[b]、ほかは nil)
  # C: src/vm.c OP_AREF
  def __fpga_op_AREF(a, b, c)
    v = __fpga_reg(b)
    unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 17 # L:TAG_OBJ L:TT_ARRAY
      return __fpga_setreg(a, c == 0 ? v : nil)
    end
    __fpga_setreg(a, __fpga_ary_ref(v, c))
  end

  # C: src/array.c mrb_ary_ref
  def __fpga_ary_ref(ary, n)
    len = __fpga_alen(ary)
    n += len if n < 0
    return nil if n < 0 || len <= n
    __fpga_aref(ary, n)
  end

  # OP_ASET: R[b][c] = R[a]
  # C: src/vm.c OP_ASET
  def __fpga_op_ASET(a, b, c)
    __fpga_ary_set(__fpga_ensure_array_type(__fpga_reg(b)), c, __fpga_reg(a))
  end

  # C: src/array.c mrb_ary_set
  def __fpga_ary_set(ary, n, val)
    len = __fpga_alen(ary)
    if n < 0
      n += len
      __fpga_raisef(IndexError, "index %i out of array", [n - len]) if n < 0
    end
    while __fpga_alen(ary) <= n # ary_expand_capa と ary_fill_with_nil
      ary.__fpga_push1(nil)
    end
    __fpga_stv(__fpga_ld32(__fpga_addr(ary) + 16) + n * 16, val) # L:A_PTR L:VALUE
  end

  # OP_APOST: *rest, post = R[a] (b = 前の数、c = 後ろの数)
  # C: src/vm.c OP_APOST
  def __fpga_op_APOST(a, b, c)
    v = __fpga_reg(a)
    v = [v] unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 17 # L:TAG_OBJ L:TT_ARRAY ary_new_from_regs
    len = __fpga_alen(v)
    pre = b
    post = c
    if len > pre + post
      rest = []
      k = pre
      while k < len - post
        rest.__fpga_push1(__fpga_aref(v, k))
        k += 1
      end
      __fpga_setreg(a, rest)
      k = 0
      while k < post
        __fpga_setreg(a + 1 + k, __fpga_aref(v, len - post + k))
        k += 1
      end
    else
      __fpga_setreg(a, [])
      idx = 0
      while idx + pre < len
        __fpga_setreg(a + 1 + idx, __fpga_aref(v, pre + idx))
        idx += 1
      end
      while idx < post
        __fpga_setreg(a + 1 + idx, nil)
        idx += 1
      end
    end
  end

  # OP_ARYSPLAT: R[a] = mrb_ary_splat(R[a])
  # C: src/vm.c OP_ARYSPLAT
  def __fpga_op_ARYSPLAT(a, b, c)
    __fpga_setreg(a, __fpga_ary_splat(__fpga_reg(a)))
  end

  # OP_INTERN: R[a] = R[a].to_sym (String から)
  # C: src/vm.c OP_INTERN
  def __fpga_op_INTERN(a, b, c)
    __fpga_setreg(a, __fpga_mkval(4, __fpga_intern_str(__fpga_ensure_string_type(__fpga_reg(a))))) # L:TAG_SYM
  end

  # OP_SYMBOL: R[a] = Pool[b] の文字列のシンボル (pool の文字列は {TAG_UNDEF, 長さ << 32 | 番地})
  # C: src/vm.c OP_SYMBOL
  def __fpga_op_SYMBOL(a, b, c)
    v = __fpga_ldv(__fpga_ld32(__fpga_irep + 12) + b * 16) # L:I_POOL L:VALUE
    __fpga_setreg(a, __fpga_mkval(4, __fpga_intern(__fpga_lo(v), __fpga_hi(v)))) # L:TAG_SYM
  end

  # OP_TCLASS: R[a] = 定義の入れ物 (check_target_class)
  # C: src/vm.c OP_TCLASS
  def __fpga_op_TCLASS(a, b, c)
    __fpga_setreg(a, __fpga_obj(__fpga_check_target_class))
  end

  # OP_DEF: R[a] (クラス) に Syms[b] を R[a+1] (Proc) で定義し、R[a] = :名前。可視性はフレームの既定 (MRB_METHOD_VDEFAULT_FL)。
  # C: src/vm.c OP_DEF
  def __fpga_op_DEF(a, b, c)
    sym = __fpga_irep_sym(__fpga_irep, b)
    __fpga_define(__fpga_addr(__fpga_reg(a)), sym, __fpga_addr(__fpga_reg(a + 1)), __fpga_scope_vis(__fpga_addr(__fpga_reg(a)), __fpga_ci)) # MRB_METHOD_VDEFAULT_FL
    __fpga_method_added(__fpga_addr(__fpga_reg(a)), sym)
    __fpga_setreg(a, __fpga_mkval(4, sym)) # L:TAG_SYM
  end

  # OP_ERR: LocalJumpError (Pool[a] の文言)
  # C: src/vm.c OP_ERR
  def __fpga_op_ERR(a, b, c)
    v = __fpga_ldv(__fpga_ld32(__fpga_irep + 12) + a * 16) # L:I_POOL L:VALUE
    __fpga_raise(LocalJumpError, __fpga_str_new(__fpga_lo(v), __fpga_hi(v)))
  end

  # C: src/vm.c OP_MATCHERR
  def __fpga_op_MATCHERR(a, b, c)
    __fpga_raise(NoMatchingPatternError, "pattern not matched") unless __fpga_reg(a)
  end

  # C: src/vm.c uvenv
  def __fpga_uvenv(up)
    p = __fpga_proc
    while up > 0
      p = __fpga_ld32(p + 12) # L:P_UPPER
      return 0 if p == 0
      up -= 1
    end
    __fpga_proc_env(p)
  end

  # OP_ARGARY (BS): 引数を super に渡す形にする。R[a] = 引数の配列、R[a+1] = キーワードの Hash (d)、その次にブロック
  # b = m1:6 r:1 m2:5 kd:1 lv:4。lv が 0 なら今の枠、ほかは lv-1 段上の env から
  # C: src/vm.c vm_op_argary
  def __fpga_op_ARGARY(a, b, c)
    m1 = __fpga_and(__fpga_shr(b, 11), 63)
    r = __fpga_and(__fpga_shr(b, 10), 1)
    m2 = __fpga_and(__fpga_shr(b, 5), 31)
    kd = __fpga_and(__fpga_shr(b, 4), 1)
    lv = __fpga_and(b, 15)
    ci = __fpga_ci
    __fpga_raise(NoMethodError, "super called outside of method") if __fpga_ld32(ci + 4) == 0 || __fpga_ci_tclass(ci) == 0 # L:CI_MID L_NOSUPER
    if lv == 0
      stack = __fpga_ld32(ci + 16) + 16 # L:CI_STACK L:VALUE regs + 1
    else
      e = __fpga_uvenv(lv - 1)
      __fpga_raise(NoMethodError, "super called outside of method") if e == 0
      __fpga_raise(NoMethodError, "super called outside of method") if __fpga_and(__fpga_shr(__fpga_ld32(e + 4), 12), 255) <= m1 + r + m2 + kd + 1 # L:H_FLAGS L:H_FLAGS_SHIFT MRB_ENV_LEN
      stack = __fpga_ld32(e + 8) + 16 # L:E_STACK L:VALUE
    end
    ary = []
    k = 0
    while k < m1
      ary.__fpga_push1(__fpga_ldv(stack + k * 16)) # L:VALUE
      k += 1
    end
    if r > 0
      rest = __fpga_ldv(stack + m1 * 16) # L:VALUE
      if __fpga_tag(rest) == 7 && __fpga_tt(__fpga_addr(rest)) == 17 # L:TAG_OBJ L:TT_ARRAY mrb_array_p
        k = 0
        len = __fpga_alen(rest)
        while k < len
          ary.__fpga_push1(__fpga_aref(rest, k))
          k += 1
        end
      end
    end
    k = 0
    while k < m2
      ary.__fpga_push1(__fpga_ldv(stack + (m1 + r + k) * 16)) # L:VALUE
      k += 1
    end
    __fpga_setreg(a, ary)
    __fpga_setreg(a + 1, __fpga_ldv(stack + (m1 + r + m2) * 16)) # L:VALUE
    __fpga_setreg(a + 2, __fpga_ldv(stack + (m1 + r + m2 + 1) * 16)) if kd > 0 # L:VALUE
  end
end
