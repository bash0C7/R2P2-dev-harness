# firmware: ヒープと GC (mruby の src/gc.c)。動かない mark & sweep。
# - 確保は回路が塊 [hp, hlim) の中で bump でする。塊が足りなければ罠 __trap_heap が空きのブロックの並びから次の塊を渡す。
#   無ければ GC し、それでも無ければ NoMemoryError (例外は V2d。それまでは止める)
# - 根: VM のスタック (底から今の窓の上まで)、フレームの Proc、起動の像のオブジェクト、回路が最近確保したブロック (arena)
# - 印: ヒープのブロックは見出しの BF_MARK、像のオブジェクトは見出しの gc の色 (GC ごとに反す)
# - GC の中では確保しない (*args や配列や文字列を作る書き方をしない)
class Object
  # 罠: 回路の確保が今の塊に収まらない (need は見出し込みのバイト数)
  def __trap_heap(need)
    __close_chunk
    return nil if __take_free(need)
    __gc
    return nil if __take_free(need)
    __fpga_halt # NoMemoryError (V2d)
  end

  # 塊の残り [hp, hlim) を空きのブロックにして並びに入れる
  def __close_chunk
    hp = __fpga_hp
    hlim = __fpga_hlim
    if hlim - hp >= 16
      __fpga_st32(hp + 0, hlim - hp) # L:B_SIZE
      __fpga_st32(hp + 4, 2) # L:B_FLAGS L:BF_FREE
      __fpga_st32(hp + 8, __fpga_image(16)) # L:IMG_free_list 次の空き (中身の先頭の語)
      __fpga_st32(64, hp) # L:IMG_free_list の語の番地 (16 × 4)
    end
    __fpga_set_heap(0, 0)
  end

  # 空きの並びから need 以上のブロックを1つ外して塊にする (最初に合うもの)
  def __take_free(need)
    prev = 64 # 並びの頭の語の番地 (像の free_list の語、16 × 4) L:IMG_free_list
    b = __fpga_image(16)
    while b > 0
      size = __fpga_ld32(b)
      nxt = __fpga_ld32(b + 8)
      if size >= need
        if prev == 64
          __fpga_st32(64, nxt)
        else
          __fpga_st32(prev + 8, nxt)
        end
        __fpga_set_heap(b, b + size)
        return true
      end
      prev = b
      b = nxt
    end
    false
  end

  # --- GC (gc.c の mrb_garbage_collect: root_scan → mark → sweep)
  def __gc
    color = 256 - __fpga_image(17) # L:GC_COLOR_BIT 印の色を反す (0 と 256)
    __fpga_st32(68, color) # L:IMG_gc_color の語の番地 (17 × 4)
    ms = __fpga_image(20) # L:IMG_mark_stack
    __fpga_st32(ms, ms + 4) # 先頭の語は mark のスタックの頂 (次に積む番地)
    # 根: VM のスタック
    a = __fpga_image(12) # L:IMG_stack
    top = __fpga_stack_top
    while a < top
      __mark_value(__fpga_ldv(a))
      a += 16 # L:VALUE
    end
    # フレームの Proc
    k = 0
    pr = __fpga_frame_proc(0)
    until pr.nil?
      __mark_obj(pr)
      k += 1
      pr = __fpga_frame_proc(k)
    end
    # 起動の像のオブジェクト
    list = __fpga_image(18) # L:IMG_roots
    n = __fpga_image(19) # L:IMG_nroots
    k = 0
    while k < n
      __mark_obj(__fpga_ld32(list + k * 4))
      k += 1
    end
    # arena (作りかけのものは中を見ずに印だけ)
    k = 0
    while k < 100 # L:ARENA
      p = __fpga_arena(k)
      __mark_raw(p) if p > 0
      k += 1
    end
    __drain
    __sweep
    __fpga_mcache_clear
    nil
  end

  def __heap_p(p)
    p >= __fpga_image(2) && p < __fpga_image(3) # L:IMG_heap_start L:IMG_heap_end
  end

  # ブロックに印を付ける (中は見ない)。付けたら true
  def __mark_raw(p)
    return false unless __heap_p(p)
    f = __fpga_ld32(p - 4) # L:B_FLAGS (見出しは中身の 8 バイト前)
    return false if __fpga_and(f, 1) == 1 # L:BF_MARK
    __fpga_st32(p - 4, f + 1)
    true
  end

  def __mark_value(v)
    __mark_obj(__fpga_addr(v)) if __fpga_tag(v) == 7 # L:TAG_OBJ
  end

  # オブジェクトに印を付けて、中を見るために mark のスタックに積む
  def __mark_obj(p)
    return if p == 0
    if __heap_p(p)
      return unless __mark_raw(p)
    else
      f = __fpga_ld32(p + 4) # L:H_FLAGS
      color = __fpga_image(17)
      return if __fpga_and(f, 256) == color # L:GC_COLOR_BIT
      __fpga_st32(p + 4, __fpga_xor(f, 256))
    end
    ms = __fpga_image(20)
    sp = __fpga_ld32(ms)
    __fpga_halt if sp >= __fpga_image(21) # mark のスタックが溢れた L:IMG_mark_stack_end
    __fpga_st32(sp, p)
    __fpga_st32(ms, sp + 4)
  end

  def __drain
    ms = __fpga_image(20)
    while __fpga_ld32(ms) > ms + 4
      sp = __fpga_ld32(ms) - 4
      __fpga_st32(ms, sp)
      __scan(__fpga_ld32(sp))
    end
  end

  # オブジェクトの中の参照に印 (型ごと、gc.c の gc_mark_children)
  def __scan(o)
    __mark_obj(__fpga_ld32(o + 0)) # L:H_CLASS
    t = __tt(o)
    if t == 8 # L:TT_OBJECT
      __mark_ivtbl(__fpga_ld32(o + 60)) # L:IV
    elsif t == 9 || t == 10 || t == 11 || t == 15 # L:TT_CLASS L:TT_MODULE L:TT_SCLASS L:TT_ICLASS
      __mark_obj(__fpga_ld32(o + 8)) # L:C_SUPER
      __mark_mt(__fpga_ld32(o + 12)) # L:C_MT
      __mark_mt(__fpga_ld32(o + 16)) # L:C_ROM
      __mark_ivtbl(__fpga_ld32(o + 60)) # L:C_IV
      __mark_obj(__fpga_ld32(o + 28)) # L:C_OUTER
    elsif t == 18 # L:TT_STRING
      __mark_raw(__fpga_ld32(o + 16)) # L:S_PTR
    elsif t == 17 # L:TT_ARRAY
      buf = __fpga_ld32(o + 16) # L:A_PTR
      __mark_raw(buf)
      n = __fpga_ld32(o + 8) # L:A_LEN
      k = 0
      while k < n
        __mark_value(__fpga_ldv(buf + k * 16))
        k += 1
      end
    elsif t == 16 # L:TT_PROC
      __mark_raw(__fpga_ld32(o + 8)) if __fpga_and(__fpga_ld32(o + 24), 3) == 0 # L:P_BODY L:P_FLAGS L:PROC_IREP
      __mark_obj(__fpga_ld32(o + 12)) # L:P_UPPER
      __mark_obj(__fpga_ld32(o + 16)) # L:P_ENV
      __mark_obj(__fpga_ld32(o + 20)) # L:P_TCLASS
    end
  end

  # メソッド表: 見出しと行の並びに印、行の値 (Proc | 可視性) の Proc に印
  def __mark_mt(t)
    return if t == 0
    __mark_raw(t)
    rows = __fpga_ld32(t + 8) # L:MT_ROWS
    __mark_raw(rows)
    capa = __fpga_ld32(t + 4) # L:MT_CAPA
    k = 0
    while k < capa
      __mark_obj(__fpga_and(__fpga_ld32(rows + k * 8 + 4), -4)) if __fpga_ld32(rows + k * 8) < 4294967295 # L:MT_EMPTY
      k += 1
    end
  end

  # iv の表: 行の値 (16 バイト) に印
  def __mark_ivtbl(t)
    return if t == 0
    __mark_raw(t)
    rows = __fpga_ld32(t + 8)
    __mark_raw(rows)
    capa = __fpga_ld32(t + 4)
    k = 0
    while k < capa
      __mark_value(__fpga_ldv(rows + k * 20 + 4)) if __fpga_ld32(rows + k * 20) < 4294967295 # L:IV_ENTRY
      k += 1
    end
  end

  # sweep (gc.c の incremental_sweep_phase): 印の無いブロックを空きに、隣の空きとつないで並びを作り直す。印は消す
  def __sweep
    b = __fpga_image(2) # L:IMG_heap_start
    last = __fpga_image(3) # L:IMG_heap_end
    __fpga_st32(64, 0)
    run = 0 # 続いている空きの先頭 (0 は無い)
    while b < last
      size = __fpga_ld32(b)
      f = __fpga_ld32(b + 4)
      if __fpga_and(f, 1) == 1 || __fpga_and(f, 4) == 4 # L:BF_MARK L:BF_PERM
        __fpga_st32(b + 4, __fpga_and(f, -2))
        run = __free_run(run, b)
      else
        run = b if run == 0
      end
      b += size
    end
    __free_run(run, last)
  end

  # run から stop の前までを1つの空きのブロックにして並びに入れる。0 を返す
  def __free_run(run, stop)
    return 0 if run == 0
    __fpga_st32(run + 0, stop - run) # L:B_SIZE
    __fpga_st32(run + 4, 2) # L:BF_FREE
    __fpga_st32(run + 8, __fpga_image(16))
    __fpga_st32(64, run)
    0
  end

  # 解放しないブロック (読み込んだ irep、実行時のシンボルの名前)
  def __alloc_perm(n)
    p = __fpga_alloc(n)
    __fpga_st32(p - 4, 4) # L:BF_PERM
    p
  end
end
