# firmware: キーワード引数 (mruby の src/vm.c の OP_SEND のキーワードの Hash、vm_op_enter のキーワードの所、OP_KEY_P / KEYEND / KARG)。
# 窓は {受け手, 引数..., kdict, ブロック}、ci->kw は CI_N の bit 4 (CI_KW_BIT)。n = 15 の配列は回路が窓に広げてある (D12)。計画 S5-3
class Object
  # SEND の nk 組のキーワードを Hash にまとめて kidx に置き、ブロックをその後ろへ (回路が続きで SEND する)
  # C: src/vm.c hash_new_from_regs
  def __fpga_op_kwpack(a, n, nk, blk)
    kidx = a + (n == 15 ? 1 : n) + 1
    kdict = __fpga_hash_new_capa(nk)
    i = 0
    while i < nk
      __fpga_hash_set(kdict, __fpga_reg(kidx + i * 2), __fpga_reg(kidx + i * 2 + 1))
      i += 1
    end
    b = blk ? __fpga_reg(kidx + nk * 2) : nil # 元の bidx (mrb_bidx(n, nk))
    __fpga_setreg(kidx, kdict)
    __fpga_setreg(kidx + 1, b)
  end

  # ENTER の遅い道 (キーワード、&nil、キーワードを渡された時): vm_op_enter をそのまま
  # C: src/vm.c vm_op_enter
  def __fpga_op_enter_kw(aspec, argc)
    ci = __fpga_ci
    m1 = __fpga_and(__fpga_shr(aspec, 18), 31) # MRB_ASPEC_REQ
    o = __fpga_and(__fpga_shr(aspec, 13), 31) # MRB_ASPEC_OPT
    r = __fpga_and(__fpga_shr(aspec, 12), 1) # MRB_ASPEC_REST
    m2 = __fpga_and(__fpga_shr(aspec, 7), 31) # MRB_ASPEC_POST
    key = __fpga_and(__fpga_shr(aspec, 2), 31) # MRB_ASPEC_KEY
    kd = key > 0 || __fpga_and(aspec, 2) > 0 ? 1 : 0 # MRB_ASPEC_KDICT
    noblock = __fpga_and(__fpga_shr(aspec, 23), 1) # MRB_ASPEC_NOBLOCK
    len = m1 + o + r + m2
    kw = __fpga_and(__fpga_ld8(ci + 0), 16) > 0 # L:CI_N L:CI_KW_BIT
    blk = __fpga_reg(argc + (kw ? 2 : 1)) # ci_bidx
    __fpga_raise(ArgumentError, "no block accepted") if noblock > 0 && __fpga_tag(blk) > 0 # L:TAG_NIL
    kdict = kw ? __fpga_reg(argc + 1) : nil # mrb_ci_kidx
    if kd == 0
      if __fpga_hash_p(kdict) && __fpga_h_size(__fpga_addr(kdict)) > 0
        argc += 1 # kdict を普通の引数に入れる (窓では引数の後ろにある)
      end
      kdict = nil
      kw = false
    end
    argv = []
    k = 1
    while k <= argc
      argv.__fpga_push1(__fpga_reg(k))
      k += 1
    end
    pr = __fpga_ld32(ci + 8) # L:CI_PROC
    if __fpga_and(__fpga_ld32(pr + 24), 256) > 0 # L:P_FLAGS L:PROC_STRICT
      if argc < m1 + m2 || (r == 0 && argc > len)
        return __fpga_op_argc(argc, m1 + m2, r == 0 ? m1 + o + m2 : -1) # argnum_error
      end
    elsif len > 1 && argc == 1 && __fpga_tag(__fpga_aref(argv, 0)) == 7 && __fpga_tt(__fpga_addr(__fpga_aref(argv, 0))) == 17 # L:TAG_OBJ L:TT_ARRAY
      argv = __fpga_aref(argv, 0)
      argc = __fpga_alen(argv)
    end
    skip = 0
    regs = []
    k = 0
    while k < len
      regs.__fpga_push1(nil)
      k += 1
    end
    if argc < len
      mlen = m2
      mlen = m1 < argc ? argc - m1 : 0 if argc < m1 + m2
      k = 0
      while k < argc - mlen # m1 と o の前から
        __fpga_ary_set(regs, k, __fpga_aref(argv, k))
        k += 1
      end
      k = 0
      while k < mlen # 後ろの必須
        __fpga_ary_set(regs, len - m2 + k, __fpga_aref(argv, argc - mlen + k))
        k += 1
      end
      __fpga_ary_set(regs, m1 + o, []) if r > 0
      skip = argc - m1 - m2 if o > 0 && argc > m1 + m2
    else
      rnum = argc - m1 - o - m2
      k = 0
      while k < m1 + o
        __fpga_ary_set(regs, k, __fpga_aref(argv, k))
        k += 1
      end
      __fpga_ary_set(regs, m1 + o, __fpga_ary_subseq(argv, m1 + o, rnum)) if r > 0
      k = 0
      while k < m2
        __fpga_ary_set(regs, m1 + o + r + k, __fpga_aref(argv, m1 + o + rnum + k))
        k += 1
      end
      skip = o
    end
    k = 0
    while k < len
      __fpga_setreg(k + 1, __fpga_aref(regs, k))
      k += 1
    end
    kw_pos = len + kd
    blk_pos = kw_pos + 1
    __fpga_setreg(blk_pos, blk)
    n = len < 15 ? len : 15
    if kd > 0
      kdict = __fpga_hash_new_capa(0) if __fpga_tag(kdict) == 0 # L:TAG_NIL
      __fpga_setreg(kw_pos, kdict)
      n = __fpga_or(n, 16) # L:CI_KW_BIT ci->kw = TRUE
    end
    __fpga_st8(ci + 0, n) # L:CI_N
    __fpga_st32(ci + 28, len) # L:CI_ARGC (D12)
    __fpga_st32(ci + 20, __fpga_ld32(ci + 20) + skip * 3) if skip > 0 # L:CI_PC 渡された省略可能の初期値を飛ばす (JMP 3 バイト)
    nlocals = __fpga_u16(__fpga_ld32(pr + 8) + 0) # L:P_BODY L:I_NLOCALS
    k = blk_pos + 1
    while k < nlocals # stack_clear
      __fpga_setreg(k, nil)
      k += 1
    end
  end

  # ENTER がキーワードの Hash を置いた枠 (ci->n が 15 なら ENTER の aspec から)
  # C: src/vm.c enter_kwpos
  def __fpga_enter_kwpos(ci)
    n = __fpga_and(__fpga_ld8(ci + 0), 15) # L:CI_N
    return n + 1 if n < 15
    aspec = __fpga_u32(__fpga_ld32(__fpga_ld32(__fpga_ld32(ci + 8) + 8) + 8) + 1) # L:CI_PROC L:P_BODY L:I_ISEQ OP_ENTER の W
    aspec = __fpga_shr(aspec, 8) # 3 バイトの W
    __fpga_and(__fpga_shr(aspec, 18), 31) + __fpga_and(__fpga_shr(aspec, 13), 31) + __fpga_and(__fpga_shr(aspec, 12), 1) + __fpga_and(__fpga_shr(aspec, 7), 31) + 1
  end

  # C: src/vm.c OP_KEY_P
  def __fpga_op_KEY_P(a, b, c)
    k = __fpga_mkval(4, __fpga_irep_sym(__fpga_irep, b)) # L:TAG_SYM
    kdict = __fpga_reg(__fpga_enter_kwpos(__fpga_ci))
    __fpga_setreg(a, __fpga_hash_p(kdict) ? __fpga_hash_key_p(kdict, k) : false)
  end

  # C: src/vm.c OP_KEYEND
  def __fpga_op_KEYEND(a, b, c)
    kdict = __fpga_reg(__fpga_enter_kwpos(__fpga_ci))
    if __fpga_hash_p(kdict) && __fpga_h_size(__fpga_addr(kdict)) > 0
      __fpga_raisef(ArgumentError, "unknown keyword: %v", [__fpga_hash_first_key(kdict)])
    end
  end

  # C: src/vm.c OP_KARG
  def __fpga_op_KARG(a, b, c)
    k = __fpga_mkval(4, __fpga_irep_sym(__fpga_irep, b)) # L:TAG_SYM
    kdict = __fpga_reg(__fpga_enter_kwpos(__fpga_ci))
    unless __fpga_hash_p(kdict) && __fpga_hash_key_p(kdict, k)
      __fpga_raisef(ArgumentError, "missing keyword: %v", [k])
    end
    __fpga_setreg(a, __fpga_hash_delete_key(kdict, k))
  end
end
