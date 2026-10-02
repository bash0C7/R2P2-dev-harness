# firmware: 記憶の管理 (mruby の src/gc.c、計画 S6)。確保 (mrb_obj_alloc_core と heap page、mrb_malloc 系) と arena。
# mrb_state.gc (struct mrb_gc) の欄は記憶の IMG の語 (tools/fpga/v2/layout.rb の gc_*)。可変長の確保は estalloc (estalloc.rb) の上。
# GC の本体 (印と sweep) は計画 S6-4。それまでは像が gc.disabled を立てて起動する (D88) ので、GC を呼ぶ所は早く戻る。
# このファイルの def は物を作る命令を持たない (firmware_test、計画 S6 §3.5)
class Object
  # mrb_int の欄 (gc_debt は上と下の 2 語)
  # C: include/mruby/gc.h mrb_gc
  def __fpga_gc_debt
    __fpga_s64(__fpga_image(1053), __fpga_image(1054)) # L:IMG_gc_debt L:IMG_gc_debt_lo
  end

  # C: include/mruby/gc.h mrb_gc
  def __fpga_gc_set_debt(v)
    __fpga_st32(1053 * 4, __fpga_shr(v, 32)) # L:IMG_gc_debt L:WORD
    __fpga_st32(1054 * 4, v) # L:IMG_gc_debt_lo L:WORD
  end

  # 記憶を 0 で埋める (libc の memset、D17)
  # C: none (D17)
  def __fpga_memzero(p, n)
    k = 0
    while k + 4 <= n
      __fpga_st32(p + k, 0)
      k += 4
    end
    while k < n
      __fpga_st8(p + k, 0)
      k += 1
    end
  end

  # C: src/gc.c mrb_realloc_simple
  def __fpga_realloc_simple(p, len)
    p2 = __fpga_basic_alloc_func(p, len)
    if p2 == 0 && len > 0 && __fpga_image(21) > 0 && __fpga_image(1064) == 0 && __fpga_image(1061) == 0 && __fpga_image(1060) == 0 # L:IMG_gc_heaps L:IMG_gc_collecting L:IMG_gc_disabled L:IMG_gc_iterating
      if __fpga_image(1056) == 2 # L:IMG_gc_state L:MRB_GC_STATE_SWEEP
        __fpga_incremental_gc_finish
      else
        __fpga_full_gc
      end
      p2 = __fpga_basic_alloc_func(p, len)
    end
    if p2 > 0 && len > 0
      __fpga_st32(1068 * 4, __fpga_image(1068) + len) # L:IMG_gc_malloc_increase L:WORD
      if p == 0 && __fpga_image(1069) > 0 && __fpga_image(1068) >= __fpga_image(1069) && # L:IMG_gc_malloc_threshold L:IMG_gc_malloc_increase
         __fpga_image(1064) == 0 && __fpga_image(1061) == 0 && __fpga_image(1060) == 0 && __fpga_image(1065) > 0 # L:IMG_gc_collecting L:IMG_gc_disabled L:IMG_gc_iterating L:IMG_gc_auto_step
        __fpga_st32(1068 * 4, 0) # L:IMG_gc_malloc_increase L:WORD
        __fpga_incremental_gc
      end
    end
    p2
  end

  # 番地 (0 は NULL)。len が 0 でなく確保できなければ NoMemoryError
  # C: src/gc.c mrb_realloc
  def __fpga_realloc(p, len)
    p2 = __fpga_realloc_simple(p, len)
    return p2 if len == 0
    __fpga_raise_nomemory if p2 == 0
    p2
  end

  # C: src/gc.c mrb_malloc
  def __fpga_malloc(len)
    __fpga_realloc(0, len)
  end

  # C: src/gc.c mrb_malloc_simple
  def __fpga_malloc_simple(len)
    __fpga_realloc_simple(0, len)
  end

  # C: src/gc.c mrb_calloc
  def __fpga_calloc(nelem, len)
    return 0 if nelem == 0 || len == 0
    __fpga_raise_alloc_overflow if nelem > 4294967295 / len # SIZE_MAX (32bit)
    p = __fpga_malloc(nelem * len)
    __fpga_memzero(p, nelem * len)
    p
  end

  # C: src/gc.c mrb_free
  def __fpga_free(p)
    __fpga_basic_alloc_func(p, 0)
  end

  # C の関数の自動変数 (struct、char の並び) の置き場 (D84): 中身を持つ String の物。arena が C の関数の間守り、GC が返す
  # C: src/gc.c mrb_temp_alloc (D84)
  def __fpga_temp_alloc(size)
    s = __fpga_slot(0, 18) # L:TT_STRING MRB_OBJ_ALLOC(mrb, MRB_TT_STRING, NULL)
    p = __fpga_malloc(size)
    __fpga_st32(s + 16, p) # L:S_PTR
    p
  end

  # C: src/error.c mrb_raise_nomemory
  def __fpga_raise_nomemory
    __fpga_exc_raise(__fpga_obj(__fpga_image(1080))) # L:IMG_nomem_err
  end

  # C: src/gc.c heap_p
  def __fpga_heap_p(object)
    page = __fpga_image(21) # L:IMG_gc_heaps
    while page > 0
      p = page + 16 # L:HP_OBJECTS
      return true if object >= p && object - p <= (128 - 1) * 64 # L:MRB_HEAP_PAGE_SIZE L:SLOT
      page = __fpga_ld32(page + 4) # L:HP_NEXT
    end
    false
  end

  # is_dead: 色が今の白でない方の白か、FREE
  # C: src/gc.c mrb_object_dead_p
  def __fpga_object_dead_p(object)
    return true unless __fpga_heap_p(object)
    f = __fpga_ld32(object + 4) # L:H_FLAGS
    other = __fpga_xor(__fpga_image(1059), 3) # L:IMG_gc_current_white_part L:GC_WHITES other_white_part
    __fpga_and(__fpga_and(__fpga_shr(f, 8), 7), __fpga_and(other, 3)) > 0 || __fpga_and(f, 255) == 4 # L:H_COLOR_SHIFT L:GC_COLOR_MASK L:GC_WHITES L:TT_FREE
  end

  # C: src/gc.c link_heap_page
  def __fpga_link_heap_page(page)
    __fpga_st32(page + 4, __fpga_image(21)) # L:HP_NEXT L:IMG_gc_heaps
    __fpga_st32(21 * 4, page) # L:IMG_gc_heaps L:WORD
    __fpga_st32(page + 8, __fpga_image(22)) # L:HP_FREE_NEXT L:IMG_gc_free_heaps
    __fpga_st32(22 * 4, page) # L:IMG_gc_free_heaps L:WORD
  end

  # C: src/gc.c init_heap_page
  def __fpga_init_heap_page(page)
    prev = 0
    k = 0
    while k < 128 # L:MRB_HEAP_PAGE_SIZE
      p = page + 16 + k * 64 # L:HP_OBJECTS L:SLOT
      __fpga_st32(p + 4, 4) # L:H_FLAGS L:TT_FREE
      __fpga_st32(p + 8, prev) # L:FREE_NEXT
      prev = p
      k += 1
    end
    __fpga_st32(page + 0, prev) # L:HP_FREELIST
  end

  # C: src/gc.c add_heap
  def __fpga_add_heap
    page = __fpga_calloc(1, 16 + 128 * 64) # L:HP_OBJECTS L:MRB_HEAP_PAGE_SIZE L:SLOT sizeof(mrb_heap_page)
    __fpga_init_heap_page(page)
    __fpga_link_heap_page(page)
  end

  # arena を広げる。溢れる前に広げる (arena_idx + 1 == arena_capa、D91)
  # C: src/gc.c gc_arena_keep (D91)
  def __fpga_gc_arena_keep
    capa = __fpga_image(1073) # L:IMG_gc_arena_capa
    if __fpga_image(1074) + 1 >= capa # L:IMG_gc_arena_idx
      newcapa = capa * 3 / 2
      __fpga_st32(1072 * 4, __fpga_realloc(__fpga_image(1072), newcapa * 4)) # L:IMG_gc_arena L:WORD
      __fpga_st32(1073 * 4, newcapa) # L:IMG_gc_arena_capa L:WORD
    end
  end

  # C: src/gc.c gc_protect
  def __fpga_gc_protect(p)
    idx = __fpga_image(1074) # L:IMG_gc_arena_idx
    __fpga_st32(__fpga_image(1072) + idx * 4, p) # L:IMG_gc_arena L:WORD
    __fpga_st32(1074 * 4, idx + 1) # L:IMG_gc_arena_idx L:WORD
  end

  # 値 obj を arena に積む (即値と RED の物は積まない)
  # C: src/gc.c mrb_gc_protect
  def __fpga_gc_protect_value(obj)
    return nil unless __fpga_tag(obj) == 7 # L:TAG_OBJ mrb_immediate_p
    p = __fpga_addr(obj)
    return nil if __fpga_and(__fpga_shr(__fpga_ld32(p + 4), 8), 7) == 7 # L:H_FLAGS L:H_COLOR_SHIFT L:GC_COLOR_MASK L:GC_RED is_red
    __fpga_gc_arena_keep
    __fpga_gc_protect(p)
  end

  # C: include/mruby.h mrb_gc_arena_save
  def __fpga_gc_arena_save
    __fpga_image(1074) # L:IMG_gc_arena_idx
  end

  # C: include/mruby.h mrb_gc_arena_restore
  def __fpga_gc_arena_restore(idx)
    __fpga_st32(1074 * 4, idx) # L:IMG_gc_arena_idx L:WORD
  end

  # 枠を 1 つ作る (見出しの語 ttype と、クラス cls)。回路の速い道 (__fpga_obj_alloc) が条件に合わない時の落ち先
  # C: src/gc.c mrb_obj_alloc_core
  def __fpga_obj_alloc_core(ttype, cls)
    debt = __fpga_gc_debt + 1
    __fpga_gc_set_debt(debt)
    if debt > 0
      __fpga_incremental_gc
      if __fpga_image(1065) == 0 && __fpga_s64(__fpga_image(1070), __fpga_image(1071)) > 0 && # L:IMG_gc_auto_step L:IMG_gc_debt_limit L:IMG_gc_debt_limit_lo
         __fpga_gc_debt > __fpga_s64(__fpga_image(1070), __fpga_image(1071)) && __fpga_image(1061) == 0 && __fpga_image(1060) == 0 # L:IMG_gc_debt_limit L:IMG_gc_debt_limit_lo L:IMG_gc_disabled L:IMG_gc_iterating
        __fpga_incremental_gc_run
      end
    end
    __fpga_gc_arena_keep
    if __fpga_image(22) == 0 # L:IMG_gc_free_heaps
      if __fpga_image(1065) > 0 && __fpga_image(1064) == 0 # L:IMG_gc_auto_step L:IMG_gc_collecting
        capacity = 0
        page = __fpga_image(21) # L:IMG_gc_heaps
        while page > 0
          capacity += 128 # L:MRB_HEAP_PAGE_SIZE
          page = __fpga_ld32(page + 4) # L:HP_NEXT
        end
        __fpga_full_gc if __fpga_image(1052) + 128 / 2 < capacity # L:IMG_gc_live_after_mark L:MRB_HEAP_PAGE_SIZE
      end
      __fpga_add_heap if __fpga_image(22) == 0 # L:IMG_gc_free_heaps
    end
    fh = __fpga_image(22) # L:IMG_gc_free_heaps
    p = __fpga_ld32(fh + 0) # L:HP_FREELIST
    __fpga_st32(fh + 0, __fpga_ld32(p + 8)) # L:HP_FREELIST L:FREE_NEXT
    __fpga_st32(22 * 4, __fpga_ld32(fh + 8)) if __fpga_ld32(fh + 0) == 0 # L:IMG_gc_free_heaps L:WORD L:HP_FREE_NEXT L:HP_FREELIST
    __fpga_st32(1051 * 4, __fpga_image(1051) + 1) # L:IMG_gc_live L:WORD
    __fpga_gc_protect(p)
    k = 0
    while k < 64 # L:SLOT RVALUE_zero
      __fpga_st32(p + k, 0)
      k += 4
    end
    __fpga_st32(p + 0, cls) # L:H_CLASS
    __fpga_st32(p + 4, __fpga_or(ttype, __fpga_shl(__fpga_image(1059), 8))) # L:H_FLAGS L:IMG_gc_current_white_part L:H_COLOR_SHIFT paint_partial_white
    p
  end

  # GC の一歩 (gc.c の incremental_gc_run は計画 S6-4)。disabled の間は何もしない (D88)
  # C: src/gc.c mrb_incremental_gc
  def __fpga_incremental_gc
    return if __fpga_image(1061) > 0 || __fpga_image(1060) > 0 || __fpga_image(1065) == 0 # L:IMG_gc_disabled L:IMG_gc_iterating L:IMG_gc_auto_step
    __fpga_incremental_gc_run
  end

  # C: src/gc.c mrb_full_gc
  def __fpga_full_gc
    return if __fpga_image(0) == 0 # L:IMG_c
    return if __fpga_image(1061) > 0 || __fpga_image(1060) > 0 # L:IMG_gc_disabled L:IMG_gc_iterating
    __fpga_incremental_gc_finish
  end

  # C の関数ポインタ (mrb_each_object_callback) の呼び出し。firmware は Proc を作らないので、写した callback を名前で分ける (D93)
  # C: none (D93)
  def __fpga_gc_callback(callback, obj, data)
    return __fpga_eq_defined_walk(obj, data) if callback == :__fpga_eq_defined_walk
    __fpga_halt
  end

  # 生きている物を heap page の順に辿り、callback (firmware の helper の名前) を呼ぶ。止めるのは callback が 1 (MRB_EACH_OBJ_BREAK) を返した時
  # C: src/gc.c gc_each_objects
  def __fpga_gc_each_objects(callback, data)
    page = __fpga_image(21) # L:IMG_gc_heaps
    while page > 0
      k = 0
      while k < 128 # L:MRB_HEAP_PAGE_SIZE
        p = page + 16 + k * 64 # L:HP_OBJECTS L:SLOT
        return if __fpga_gc_callback(callback, p, data) == 1 # MRB_EACH_OBJ_BREAK
        k += 1
      end
      page = __fpga_ld32(page + 4) # L:HP_NEXT
    end
  end

  # FREE と死んだ物を除いて辿る
  # C: src/gc.c mrb_gc_each_live_object
  def __fpga_gc_each_live_object(callback, data)
    page = __fpga_image(21) # L:IMG_gc_heaps
    while page > 0
      k = 0
      while k < 128 # L:MRB_HEAP_PAGE_SIZE
        p = page + 16 + k * 64 # L:HP_OBJECTS L:SLOT
        unless __fpga_and(__fpga_ld32(p + 4), 255) == 4 || __fpga_object_dead_p(p) # L:H_FLAGS L:TT_FREE
          return if __fpga_gc_callback(callback, p, data) == 1 # MRB_EACH_OBJ_BREAK
        end
        k += 1
      end
      page = __fpga_ld32(page + 4) # L:HP_NEXT
    end
  end
end
