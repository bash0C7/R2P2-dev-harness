# firmware: 起動、.mrb の loader (mruby の src/load.c の read_irep)、シンボル (src/symbol.c の mrb_intern)、
# メソッドの探索の罠 (src/class.c の mrb_method_search_vm)、命令の罠 (src/vm.c の各 OP の遅い道)。
# コアで走る mruby ソースコード。記憶の配置は tools/fpga/v2/layout.rb (数の横の `# L:名前` は firmware_test が layout と照らす)。
class Object
  # 起動 (mruby の mrb_open の後の mrb_load_irep): 像のプログラムを順に読み込み、main で実行する
  def __boot
    progs = __fpga_image(10) # L:IMG_programs
    n = __fpga_image(11) # L:IMG_nprograms
    i = 0
    while i < n
      ir = __load(__fpga_ld32(progs + i * 8))
      __fpga_run(ir, self)
      i += 1
    end
    __fpga_halt
  end

  # --- .mrb の読み込み (load.c の read_irep_record_1)。blob は RITE0400 の先頭の番地。一番外の irep の番地を返す
  def __load(blob)
    cur = __fpga_alloc(8)
    __fpga_st32(cur, blob + 32) # 見出し 20 + IREP の section の見出し 12
    __read_irep(cur)
  end

  def __u16(p)
    __fpga_ld8(p) * 256 + __fpga_ld8(p + 1)
  end

  def __u32(p)
    __u16(p) * 65536 + __u16(p + 2)
  end

  # cur (8 バイトの領域) の番地から irep を1つ読み (子も)、cur を進める
  def __read_irep(cur)
    rec = __fpga_ld32(cur)
    nlocals = __u16(rec + 4)
    nregs = __u16(rec + 6)
    rlen = __u16(rec + 8)
    clen = __u16(rec + 10)
    ilen = __u32(rec + 12)
    iseq = rec + 16
    catch = iseq + ilen
    p = catch + 13 * clen
    plen = __u16(p)
    p += 2
    pool = __fpga_alloc((plen > 0 ? plen : 1) * 16) # L:VALUE
    k = 0
    while k < plen
      tt = __fpga_ld8(p)
      p += 1
      if tt == 0 || tt == 2 # IREP_TT_STR / SSTR: {TAG_UNDEF, 長さ << 32 | 番地}
        len = __u16(p)
        __fpga_stv(pool + k * 16, __fpga_mkval(6, len * 4294967296 + p + 2)) # L:TAG_UNDEF
        p += 3 + len
      elsif tt == 1 # INT32
        v = __u32(p)
        v -= 4294967296 if v >= 2147483648
        __fpga_stv(pool + k * 16, v)
        p += 4
      elsif tt == 3 # INT64
        __fpga_stv(pool + k * 16, __s64(__u32(p), __u32(p + 4)))
        p += 8
      elsif tt == 5 # FLOAT: IEEE 754 の double を little endian で (load.c の str_to_double)
        lo = __fpga_ld8(p) + __fpga_ld8(p + 1) * 256 + __fpga_ld8(p + 2) * 65536 + __fpga_ld8(p + 3) * 16777216
        hi = __fpga_ld8(p + 4) + __fpga_ld8(p + 5) * 256 + __fpga_ld8(p + 6) * 65536 + __fpga_ld8(p + 7) * 16777216
        __fpga_stv(pool + k * 16, __fpga_mkval(5, __s64(hi, lo))) # L:TAG_FLOAT
        p += 8
      else
        __fpga_halt # bigint (R2P2 の build に無い)
      end
      k += 1
    end
    slen = __u16(p)
    p += 2
    syms = __fpga_alloc((slen > 0 ? slen : 1) * 4)
    k = 0
    while k < slen
      len = __u16(p)
      if len == 65535 # MRB_DUMP_NULL_SYM_LEN
        __fpga_st32(syms + k * 4, 4294967295) # L:NULL_SYM
        p += 2
      else
        __fpga_st32(syms + k * 4, __intern(p + 2, len))
        p += 3 + len
      end
      k += 1
    end
    ir = __fpga_alloc(44) # L:IREP
    __fpga_st32(ir, nlocals * 65536 + nregs) # L:I_NLOCALS
    __fpga_st32(ir + 4, ilen) # L:I_ILEN
    __fpga_st32(ir + 8, iseq) # L:I_ISEQ
    __fpga_st32(ir + 12, pool) # L:I_POOL
    __fpga_st32(ir + 16, plen) # L:I_PLEN
    __fpga_st32(ir + 20, syms) # L:I_SYMS
    __fpga_st32(ir + 24, slen) # L:I_SLEN
    reps = __fpga_alloc((rlen > 0 ? rlen : 1) * 4)
    __fpga_st32(ir + 28, reps) # L:I_REPS
    __fpga_st32(ir + 32, rlen) # L:I_RLEN
    __fpga_st32(ir + 36, catch) # L:I_CATCH
    __fpga_st32(ir + 40, clen) # L:I_CLEN
    __fpga_st32(cur, p)
    k = 0
    while k < rlen
      __fpga_st32(reps + k * 4, __read_irep(cur))
      k += 1
    end
    ir
  end

  # 上位・下位 32bit から 64bit の符号付き
  def __s64(hi, lo)
    hi >= 2147483648 ? (hi - 4294967296) * 4294967296 + lo : hi * 4294967296 + lo
  end

  # --- シンボル (symbol.c)。表は FNV-1a 32bit の開番地法 (image.rb の intern と同じ)。番号 = 行の位置
  def __intern(ptr, len)
    h = 2166136261
    k = 0
    while k < len
      h = __fpga_and(__fpga_xor(h, __fpga_ld8(ptr + k)) * 16777619, 4294967295)
      k += 1
    end
    tab = __fpga_image(4) # L:IMG_sym_table
    mask = __fpga_image(5) - 1 # L:IMG_sym_capa
    i = __fpga_and(h, mask)
    while true
      p = __fpga_ld32(tab + i * 8)
      if p == 0 # 空き: 名前は .mrb の中を指す (mrb_intern_static)
        __fpga_st32(tab + i * 8, ptr)
        __fpga_st32(tab + i * 8 + 4, len)
        return i
      end
      return i if __fpga_ld32(tab + i * 8 + 4) == len && __memeq(p, ptr, len)
      i = __fpga_and(i + 1, mask)
    end
  end

  def __memeq(a, b, n)
    k = 0
    while k < n
      return false unless __fpga_ld8(a + k) == __fpga_ld8(b + k)
      k += 1
    end
    true
  end

  # --- メソッドの探索の罠 (class.c の mrb_method_search_vm)。cls から親へ、実行時の表、ROM の表の順に引く。
  # 見つかれば cache に入れて Proc を返す。無ければ nil (回路が method_missing を引き直す)。
  # 自分がまた罠に入らないよう、中では命令と __fpga_* だけを使う (!= や ! はメソッドの呼び出しになるので使わない)
  def __trap_lookup(cls, sym)
    c = __fpga_addr(cls)
    s = __fpga_addr(sym)
    while c > 0
      off = 12 # L:C_MT、次は 16 # L:C_ROM
      while off < 20
        t = __fpga_ld32(c + off)
        if t > 0
          capa = __fpga_ld32(t + 4) # L:MT_CAPA
          rows = __fpga_ld32(t + 8) # L:MT_ROWS
          i = __fpga_and(s, capa - 1)
          n = 0
          while n < capa
            e = __fpga_ld32(rows + i * 8) # L:MT_ENTRY
            if e == 4294967295 # L:MT_EMPTY
              n = capa
            elsif e == s
              pr = __fpga_ld32(rows + i * 8 + 4)
              __fpga_mcache_fill(__fpga_addr(cls), s, pr)
              return __fpga_obj(pr)
            else
              i = __fpga_and(i + 1, capa - 1)
              n += 1
            end
          end
        end
        off += 4
      end
      c = __fpga_ld32(c + 8) # L:C_SUPER
    end
    nil
  end

  # --- メソッド表 (class.c の mt)。開番地法、詰め率 3/4 を超えたら倍の行の並びに写す (見出しは同じ番地のまま)
  def __mt_set(t, sym, val)
    count = __fpga_ld32(t) # L:MT_COUNT
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    if (count + 1) * 4 > capa * 3
      __mt_grow(t, capa * 2)
      capa *= 2
    end
    rows = __fpga_ld32(t + 8) # L:MT_ROWS
    i = __fpga_and(sym, capa - 1)
    while true
      e = __fpga_ld32(rows + i * 8)
      if e == 4294967295 || e == sym
        __fpga_st32(t, count + 1) if e == 4294967295
        __fpga_st32(rows + i * 8, sym)
        __fpga_st32(rows + i * 8 + 4, val)
        return val
      end
      i = __fpga_and(i + 1, capa - 1)
    end
  end

  def __mt_grow(t, capa)
    old = __fpga_ld32(t + 8)
    ocapa = __fpga_ld32(t + 4)
    rows = __fpga_alloc(capa * 8)
    k = 0
    while k < capa
      __fpga_st32(rows + k * 8, 4294967295)
      k += 1
    end
    __fpga_st32(t + 8, rows)
    __fpga_st32(t + 4, capa)
    __fpga_st32(t, 0)
    k = 0
    while k < ocapa
      e = __fpga_ld32(old + k * 8)
      __mt_set(t, e, __fpga_ld32(old + k * 8 + 4)) if e < 4294967295
      k += 1
    end
  end

  # --- オブジェクトを作る
  def __proc_new(irep, target)
    pr = __fpga_alloc(64) # L:SLOT
    __fpga_st32(pr, __fpga_addr(__fpga_core(10))) # L:CORE_PROC
    __fpga_st32(pr + 4, 16) # L:TT_PROC
    __fpga_st32(pr + 8, irep) # L:P_BODY
    __fpga_st32(pr + 12, 0)
    __fpga_st32(pr + 16, 0)
    __fpga_st32(pr + 20, target) # L:P_TCLASS
    __fpga_st32(pr + 24, 0) # L:P_FLAGS
    pr
  end

  # 記憶の ptr から len バイトの String (string.c の mrb_str_new)
  def __str_new(ptr, len)
    s = __fpga_alloc(64) # L:SLOT
    buf = __fpga_alloc(len + 1)
    __fpga_copy(buf, ptr, len)
    __fpga_st8(buf + len, 0)
    __fpga_st32(s, __fpga_addr(__fpga_core(9))) # L:CORE_STRING
    __fpga_st32(s + 4, 18) # L:TT_STRING
    __fpga_st32(s + 8, len) # L:S_LEN
    __fpga_st32(s + 12, len) # L:S_CAPA
    __fpga_st32(s + 16, buf) # L:S_PTR
    __fpga_obj(s)
  end

  def __irep_sym(ir, k)
    __fpga_ld32(__fpga_ld32(ir + 20) + k * 4) # L:I_SYMS
  end

  # --- 命令の罠 (vm.c の OP_*)。a, b, c は命令の operand、__fpga_reg / __fpga_setreg は罠を起こしたフレームのレジスタ
  # OP_STRING: R[a] = str_dup(Pool[b])
  def __op_STRING(a, b, c)
    v = __fpga_ldv(__fpga_ld32(__fpga_irep + 12) + b * 16) # L:I_POOL
    __fpga_setreg(a, __str_new(__fpga_lo(v), __fpga_hi(v)))
  end

  # OP_TDEF: target_class に Syms[b] を Irep[c] で定義し、R[a] = :名前 (定義はこの時点から効く)
  def __op_TDEF(a, b, c)
    ir = __fpga_irep
    sym = __irep_sym(ir, b)
    target = __fpga_addr(__fpga_tclass)
    __mt_set(__fpga_ld32(target + 12), sym, __proc_new(__fpga_ld32(__fpga_ld32(ir + 28) + c * 4), target)) # L:C_MT L:I_REPS
    __fpga_mcache_clear
    __fpga_setreg(a, __fpga_mkval(4, sym)) # L:TAG_SYM
  end

  # 例外は V2d。それまでは止める
  def __op_argc(given, min, max)
    __fpga_halt
  end

  def __op_overflow(a, op)
    __fpga_halt
  end

  def __op_zerodiv(a)
    __fpga_halt
  end
end
