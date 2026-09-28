# firmware: estalloc (picoruby-machine の lib/estalloc/estalloc.c、TLSF の確保) と、その上の picoruby-machine の src/heap.c と
# src/mruby/alloc.c (mrb_basic_alloc_func)。組み込みの build の形: ESTALLOC_ADDRESS_24BIT、ESTALLOC_ALIGNMENT 8、ESTALLOC_DEBUG 無し。
# 32bit の配置 (tools/fpga/v2/layout.rb の EST_* / MP_* / FB_*)。記憶は big endian だが、ブロックの並びと番地は C と同じ。
# 同じ file を CRuby の tools/fpga/v2/est_host.rb も読む (像の pool を作る、C の .so と比べる。計画 S6 §6)。
# ENTER_CRITICAL / EXIT_CRITICAL は、enter_critical / exit_critical が NULL の時と同じで何もしない (板は est_set_critical_section を呼ばない)
class Object
  # C: picoruby-machine/lib/estalloc/estalloc.c nlz16
  def __fpga_est_nlz16(x)
    return 16 if x == 0
    n = 1
    if __fpga_shr(x, 8) == 0
      n += 8
      x = __fpga_and(__fpga_shl(x, 8), 65535)
    end
    if __fpga_shr(x, 12) == 0
      n += 4
      x = __fpga_and(__fpga_shl(x, 4), 65535)
    end
    if __fpga_shr(x, 14) == 0
      n += 2
      x = __fpga_and(__fpga_shl(x, 2), 65535)
    end
    n - __fpga_shr(x, 15)
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c nlz8
  def __fpga_est_nlz8(x)
    return 8 if x == 0
    n = 1
    if __fpga_shr(x, 4) == 0
      n += 4
      x = __fpga_and(__fpga_shl(x, 4), 255)
    end
    if __fpga_shr(x, 6) == 0
      n += 2
      x = __fpga_and(__fpga_shl(x, 2), 255)
    end
    n - __fpga_shr(x, 7)
  end

  # u16 の欄 (free_fli_bitmap)
  # C: picoruby-machine/lib/estalloc/estalloc.c MEMORY_POOL
  def __fpga_est_ld16(a)
    __fpga_ld8(a) * 256 + __fpga_ld8(a + 1)
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c MEMORY_POOL
  def __fpga_est_st16(a, v)
    __fpga_st8(a, __fpga_shr(v, 8))
    __fpga_st8(a + 1, v)
  end

  # BLOCK_SIZE(p): 見出しの size の下 3bit (ALIGNMENT_MASK) は印
  # C: picoruby-machine/lib/estalloc/estalloc.c BLOCK_SIZE
  def __fpga_est_block_size(p)
    __fpga_and(__fpga_ld32(p), -8) # ~ALIGNMENT_MASK
  end

  # free_blocks[index] (pool の見出しの中の並び)
  # C: picoruby-machine/lib/estalloc/estalloc.c MEMORY_POOL
  def __fpga_est_fb(pool, index)
    __fpga_ld32(pool + 52 + index * 4) # L:MP_FREE_BLOCKS
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c MEMORY_POOL
  def __fpga_est_set_fb(pool, index, v)
    __fpga_st32(pool + 52 + index * 4, v) # L:MP_FREE_BLOCKS
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c calc_index
  def __fpga_est_calc_index(alloc_size)
    return 80 - 1 if __fpga_shr(alloc_size, 9 + 3 + 5) > 0 # L:SIZE_FREE_BLOCKS L:ESTALLOC_FLI_BIT_WIDTH L:ESTALLOC_SLI_BIT_WIDTH L:ESTALLOC_IGNORE_LSBS
    fli = 16 - __fpga_est_nlz16(__fpga_shr(alloc_size, 3 + 5)) # L:ESTALLOC_SLI_BIT_WIDTH L:ESTALLOC_IGNORE_LSBS
    shift = fli == 0 ? 5 : 5 - 1 + fli # L:ESTALLOC_IGNORE_LSBS
    sli = __fpga_and(__fpga_shr(alloc_size, shift), 7) # (1 << ESTALLOC_SLI_BIT_WIDTH) - 1
    fli * 8 + sli # fli << ESTALLOC_SLI_BIT_WIDTH
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c add_free_block
  def __fpga_est_add_free_block(pool, target)
    __fpga_st32(target, __fpga_and(__fpga_ld32(target), -2)) # SET_FREE_BLOCK
    size = __fpga_est_block_size(target)
    __fpga_st32(target + size - 4, target) # top_adrs (sizeof(FREE_BLOCK *))
    index = __fpga_est_calc_index(size)
    fli = __fpga_shr(index, 3) # L:ESTALLOC_SLI_BIT_WIDTH
    sli = __fpga_and(index, 7)
    __fpga_est_st16(pool + 36, __fpga_or(__fpga_est_ld16(pool + 36), __fpga_shr(32768, fli))) # L:MP_FLI_BITMAP L:MSB_BIT1_FLI
    __fpga_st8(pool + 38 + fli, __fpga_or(__fpga_ld8(pool + 38 + fli), __fpga_shr(128, sli))) # L:MP_SLI_BITMAP L:MSB_BIT1_SLI
    __fpga_st32(target + 8, 0) # L:FB_PREV_FREE
    nxt = __fpga_est_fb(pool, index)
    __fpga_st32(target + 4, nxt) # L:FB_NEXT_FREE
    __fpga_st32(nxt + 8, target) if nxt > 0 # L:FB_PREV_FREE
    __fpga_est_set_fb(pool, index, target)
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c remove_free_block
  def __fpga_est_remove_free_block(pool, target)
    prev = __fpga_ld32(target + 8) # L:FB_PREV_FREE
    nxt = __fpga_ld32(target + 4) # L:FB_NEXT_FREE
    if prev == 0
      index = __fpga_est_calc_index(__fpga_est_block_size(target))
      __fpga_est_set_fb(pool, index, nxt)
      if nxt == 0
        fli = __fpga_shr(index, 3) # L:ESTALLOC_SLI_BIT_WIDTH
        sli = __fpga_and(index, 7)
        bits = __fpga_and(__fpga_ld8(pool + 38 + fli), __fpga_xor(__fpga_shr(128, sli), 255)) # L:MP_SLI_BITMAP L:MSB_BIT1_SLI
        __fpga_st8(pool + 38 + fli, bits) # L:MP_SLI_BITMAP
        if bits == 0
          __fpga_est_st16(pool + 36, __fpga_and(__fpga_est_ld16(pool + 36), __fpga_xor(__fpga_shr(32768, fli), 65535))) # L:MP_FLI_BITMAP L:MSB_BIT1_FLI
        end
      end
    else
      __fpga_st32(prev + 4, nxt) # L:FB_NEXT_FREE
    end
    __fpga_st32(nxt + 8, prev) if nxt > 0 # L:FB_PREV_FREE
  end

  # 分けた後ろのブロック (分けない時は 0)
  # C: picoruby-machine/lib/estalloc/estalloc.c split_block
  def __fpga_est_split_block(target, size)
    bsize = __fpga_est_block_size(target)
    return 0 if bsize - size <= 32 # L:ESTALLOC_MIN_MEMORY_BLOCK_SIZE
    split = target + size
    __fpga_st32(split, bsize - size)
    __fpga_st32(target, __fpga_or(size, __fpga_and(__fpga_ld32(target), 7))) # L:ALIGNMENT_MASK
    split
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c merge_block
  def __fpga_est_merge_block(target, nxt)
    __fpga_st32(target, __fpga_and(__fpga_ld32(target) + __fpga_est_block_size(nxt), 4294967295)) # size は ESTALLOC_MEMSIZE_T (uint32)
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_init
  def __fpga_est_init(ptr, size)
    size = __fpga_and(size, -8) # size &= ~ALIGNMENT_MASK
    k = 0
    while k < 376 # L:POOL_HEADER_SIZE (MEMORY_POOL zero_pool = {0})
      __fpga_st32(ptr + k, 0)
      k += 4
    end
    __fpga_st32(ptr + 32, size) # L:MP_SIZE
    sentinel_size = 8 # L:USED_BLOCK_SIZE (sizeof(USED_BLOCK)、ALIGNMENT の倍数)
    free_size = size - 376 - sentinel_size # L:POOL_HEADER_SIZE
    free_block = ptr + 376 # L:POOL_HEADER_SIZE BPOOL_TOP
    used_block = free_block + free_size
    __fpga_st32(free_block, __fpga_or(free_size, 2)) # flag prev=1, used=0
    __fpga_st32(used_block, __fpga_or(sentinel_size, 1)) # flag prev=0, used=1
    __fpga_est_add_free_block(ptr, free_block)
    ptr
  end

  # 要る大きさ (見出し込み、ALIGNMENT に切り上げ、最小のブロック以上)
  # C: picoruby-machine/lib/estalloc/estalloc.c est_malloc
  def __fpga_est_alloc_size(size)
    a = __fpga_and(size + 8, 4294967295) # L:USED_BLOCK_SIZE (ESTALLOC_MEMSIZE_T)
    a = __fpga_and(a + __fpga_and(0 - a, 7), 4294967295) # L:ALIGNMENT_MASK
    a < 32 ? 32 : a # L:ESTALLOC_MIN_MEMORY_BLOCK_SIZE
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_malloc
  def __fpga_est_malloc(pool, size)
    alloc_size = __fpga_est_alloc_size(size)
    pool_end = pool + __fpga_ld32(pool + 32) # L:MP_SIZE BPOOL_END
    return 0 if pool_end - alloc_size < pool + 376 # L:POOL_HEADER_SIZE request size is too large
    index = __fpga_est_calc_index(alloc_size)
    fli = 0
    sli = 0
    target = __fpga_est_fb(pool, index)
    step = 0 # 0 まだ、1 FOUND_TARGET_BLOCK、2 FOUND_FLI_SLI、3 SPLIT_BLOCK
    if target > 0 && __fpga_est_block_size(target) >= alloc_size
      fli = __fpga_shr(index, 3) # L:ESTALLOC_SLI_BIT_WIDTH
      sli = __fpga_and(index, 7)
      step = 1
    end
    if step == 0
      index += 1
      target = __fpga_est_fb(pool, index)
      fli = __fpga_shr(index, 3) # L:ESTALLOC_SLI_BIT_WIDTH
      sli = __fpga_and(index, 7)
      step = 1 if target > 0
    end
    if step == 0
      masked = __fpga_and(__fpga_ld8(pool + 38 + fli), __fpga_shr(128, sli) - 1) # L:MP_SLI_BITMAP L:MSB_BIT1_SLI
      if masked > 0
        sli = __fpga_est_nlz8(masked)
        step = 2
      end
    end
    if step == 0
      masked = __fpga_and(__fpga_est_ld16(pool + 36), __fpga_shr(32768, fli) - 1) # L:MP_FLI_BITMAP L:MSB_BIT1_FLI
      if masked > 0
        fli = __fpga_est_nlz16(masked)
        sli = __fpga_est_nlz8(__fpga_ld8(pool + 38 + fli)) # L:MP_SLI_BITMAP
        step = 2
      end
    end
    if step == 0
      index -= 1
      target = __fpga_est_fb(pool, index)
      while target > 0
        if __fpga_est_block_size(target) >= alloc_size
          __fpga_est_remove_free_block(pool, target)
          step = 3
          break
        end
        target = __fpga_ld32(target + 4) # L:FB_NEXT_FREE
      end
      return 0 if step == 0
    end
    if step == 2 # FOUND_FLI_SLI
      index = fli * 8 + sli # (fli << ESTALLOC_SLI_BIT_WIDTH) + sli
      target = __fpga_est_fb(pool, index)
      return 0 if target == 0
      step = 1
    end
    if step == 1 # FOUND_TARGET_BLOCK
      return 0 if target + alloc_size > pool_end # Check pool boundary
      nxt = __fpga_ld32(target + 4) # L:FB_NEXT_FREE
      __fpga_est_set_fb(pool, index, nxt)
      if nxt == 0
        bits = __fpga_and(__fpga_ld8(pool + 38 + fli), __fpga_xor(__fpga_shr(128, sli), 255)) # L:MP_SLI_BITMAP L:MSB_BIT1_SLI
        __fpga_st8(pool + 38 + fli, bits) # L:MP_SLI_BITMAP
        if bits == 0
          __fpga_est_st16(pool + 36, __fpga_and(__fpga_est_ld16(pool + 36), __fpga_xor(__fpga_shr(32768, fli), 65535))) # L:MP_FLI_BITMAP L:MSB_BIT1_FLI
        end
      else
        __fpga_st32(nxt + 8, 0) # L:FB_PREV_FREE
      end
    end
    # SPLIT_BLOCK
    release = __fpga_est_split_block(target, alloc_size)
    if release > 0
      __fpga_st32(release, __fpga_or(__fpga_ld32(release), 2)) # SET_PREV_USED
      __fpga_est_add_free_block(pool, release)
    else
      nxt = target + __fpga_est_block_size(target) # PHYS_NEXT
      __fpga_st32(nxt, __fpga_or(__fpga_ld32(nxt), 2)) # SET_PREV_USED
    end
    __fpga_st32(target, __fpga_or(__fpga_ld32(target), 1)) # SET_USED_BLOCK
    target + 8 # L:USED_BLOCK_SIZE
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_permalloc
  def __fpga_est_permalloc(pool, size)
    alloc_size = __fpga_and(size + __fpga_and(0 - size, 7), 4294967295) # L:ALIGNMENT_MASK
    pool_end = pool + __fpga_ld32(pool + 32) # L:MP_SIZE BPOOL_END
    tail = pool + 376 # L:POOL_HEADER_SIZE BPOOL_TOP
    prev = tail
    while true
      prev = tail
      tail = tail + __fpga_est_block_size(tail)
      break if tail + __fpga_est_block_size(tail) >= pool_end
    end
    fallback = __fpga_and(__fpga_ld32(prev), 1) > 0 # IS_USED_BLOCK(prev)
    fallback = true if fallback == false && __fpga_est_block_size(prev) - 8 < alloc_size # L:USED_BLOCK_SIZE
    return __fpga_est_malloc(pool, size) if fallback
    __fpga_est_remove_free_block(pool, prev)
    free_size = __fpga_est_block_size(prev) - alloc_size
    if free_size <= 32 # L:ESTALLOC_MIN_MEMORY_BLOCK_SIZE
      __fpga_st32(prev, __fpga_and(__fpga_ld32(prev) + __fpga_est_block_size(tail), 4294967295))
      __fpga_st32(prev, __fpga_or(__fpga_ld32(prev), 1)) # SET_USED_BLOCK
      tail = prev
    else
      tail_size = __fpga_and(__fpga_ld32(tail) + alloc_size, 4294967295) # w/ flags
      tail -= alloc_size
      __fpga_st32(tail, tail_size)
      __fpga_st32(prev, __fpga_ld32(prev) - alloc_size) # w/ flags
      __fpga_est_add_free_block(pool, prev)
    end
    tail + 8 # L:USED_BLOCK_SIZE
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_calloc
  def __fpga_est_calloc(pool, nmemb, size)
    total = __fpga_and(nmemb * size, 4294967295) # unsigned int
    ptr = __fpga_est_malloc(pool, total)
    if ptr > 0
      k = 0
      while k < total
        __fpga_st8(ptr + k, 0)
        k += 1
      end
    end
    ptr
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_free
  def __fpga_est_free(pool, ptr)
    return if ptr == 0
    target = ptr - 8 # L:USED_BLOCK_SIZE BLOCK_ADRS
    nxt = target + __fpga_est_block_size(target) # PHYS_NEXT
    if __fpga_and(__fpga_ld32(nxt), 1) == 0 # IS_FREE_BLOCK
      __fpga_est_remove_free_block(pool, nxt)
      __fpga_est_merge_block(target, nxt)
    else
      __fpga_st32(nxt, __fpga_and(__fpga_ld32(nxt), -3)) # SET_PREV_FREE
    end
    if __fpga_and(__fpga_ld32(target), 2) == 0 # IS_PREV_FREE
      prev = __fpga_ld32(target - 4) # 前のブロックの top_adrs (sizeof(FREE_BLOCK *))
      __fpga_est_remove_free_block(pool, prev)
      __fpga_est_merge_block(prev, target)
      target = prev
    end
    __fpga_est_add_free_block(pool, target)
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_realloc
  def __fpga_est_realloc(pool, ptr, size)
    return __fpga_est_malloc(pool, size) if ptr == 0
    target = ptr - 8 # L:USED_BLOCK_SIZE BLOCK_ADRS
    alloc_size = __fpga_est_alloc_size(size)
    copy = false # ALLOC_AND_COPY
    if alloc_size > __fpga_est_block_size(target)
      nxt = target + __fpga_est_block_size(target) # PHYS_NEXT
      if __fpga_and(__fpga_ld32(nxt), 1) > 0 || __fpga_est_block_size(target) + __fpga_est_block_size(nxt) < alloc_size
        copy = true
      else
        __fpga_est_remove_free_block(pool, nxt)
        __fpga_est_merge_block(target, nxt)
      end
    end
    if copy
      copy_size = __fpga_est_block_size(target) - 8 # L:USED_BLOCK_SIZE
      new_ptr = __fpga_est_malloc(pool, size)
      return 0 if new_ptr == 0 # ENOMEM
      __fpga_copy(new_ptr, ptr, copy_size)
      __fpga_est_free(pool, ptr)
      return new_ptr
    end
    nxt = target + __fpga_est_block_size(target) # PHYS_NEXT
    release = __fpga_est_split_block(target, alloc_size)
    if release > 0
      __fpga_st32(release, __fpga_or(__fpga_ld32(release), 2)) # SET_PREV_USED
    else
      __fpga_st32(nxt, __fpga_or(__fpga_ld32(nxt), 2)) # SET_PREV_USED
      return ptr
    end
    if __fpga_and(__fpga_ld32(nxt), 1) == 0 # IS_FREE_BLOCK
      __fpga_est_remove_free_block(pool, nxt)
      __fpga_est_merge_block(release, nxt)
    else
      __fpga_st32(nxt, __fpga_and(__fpga_ld32(nxt), -3)) # SET_PREV_FREE
    end
    __fpga_est_add_free_block(pool, release)
    ptr
  end

  # C: picoruby-machine/lib/estalloc/estalloc.c est_usable_size
  def __fpga_est_usable_size(pool, ptr)
    __fpga_est_block_size(ptr - 8) - 8 # L:USED_BLOCK_SIZE
  end

  # est->stat (ESTALLOC_STAT) に total、used、free、max_free、frag を書く。frag は -1 から数える (uint32)
  # C: picoruby-machine/lib/estalloc/estalloc.c est_take_statistics
  def __fpga_est_take_statistics(pool)
    pool_end = pool + __fpga_ld32(pool + 32) # L:MP_SIZE BPOOL_END
    block = pool + 376 # L:POOL_HEADER_SIZE BPOOL_TOP
    flag = __fpga_and(__fpga_ld32(block), 1)
    used = 0
    free = 0
    max_free = 0
    frag = 4294967295 # -1 (uint32)
    while block < pool_end
      bsize = __fpga_est_block_size(block)
      nxt = block + bsize
      if bsize == 0 || nxt <= block || nxt > pool_end
        __fpga_st32(pool + 20, 1) # L:EST_ERROR_MESSAGE "broken memory block chain" (文字列の代わりに 1)
        break
      end
      if __fpga_and(__fpga_ld32(block), 1) == 0
        free += bsize
        max_free = bsize if max_free < bsize
      else
        used += bsize
      end
      if flag == __fpga_and(__fpga_ld32(block), 1)
      else
        frag = __fpga_and(frag + 1, 4294967295)
        flag = __fpga_and(__fpga_ld32(block), 1)
      end
      block = nxt
    end
    __fpga_st32(pool + 0, __fpga_ld32(pool + 32)) # L:EST_STAT_TOTAL L:MP_SIZE
    __fpga_st32(pool + 4, used) # L:EST_STAT_USED
    __fpga_st32(pool + 8, free) # L:EST_STAT_FREE
    __fpga_st32(pool + 12, max_free) # L:EST_STAT_MAX_FREE
    __fpga_st32(pool + 16, frag) # L:EST_STAT_FRAG
  end

  # --- picoruby-machine の src/heap.c。static の picorb_heap_estalloc / start / end は像の見出しの欄 (D18)
  # C: picoruby-machine/src/heap.c picorb_heap_init
  def __fpga_picorb_heap_init(heap, size)
    if heap == 0 || size == 0 || size > 4294967295 # UINT_MAX
      __fpga_st32(1105 * 4, 0) # L:IMG_est_heap L:WORD
      __fpga_st32(1106 * 4, 0) # L:IMG_est_heap_start L:WORD
      __fpga_st32(1107 * 4, 0) # L:IMG_est_heap_end L:WORD
      return -1
    end
    __fpga_st32(1105 * 4, __fpga_est_init(heap, size)) # L:IMG_est_heap L:WORD
    __fpga_st32(1106 * 4, heap) # L:IMG_est_heap_start L:WORD
    __fpga_st32(1107 * 4, heap + size) # L:IMG_est_heap_end L:WORD
    0
  end

  # C: picoruby-machine/src/heap.c picorb_heap_malloc
  def __fpga_picorb_heap_malloc(size)
    est = __fpga_image(1105) # L:IMG_est_heap
    return 0 if est == 0 || size > 4294967295 # UINT_MAX
    __fpga_est_malloc(est, size)
  end

  # C: picoruby-machine/src/heap.c picorb_heap_realloc
  def __fpga_picorb_heap_realloc(ptr, size)
    return __fpga_picorb_heap_malloc(size) if ptr == 0
    if size == 0
      __fpga_picorb_heap_free(ptr)
      return 0
    end
    est = __fpga_image(1105) # L:IMG_est_heap
    return 0 if est == 0 || size > 4294967295 # UINT_MAX
    __fpga_est_realloc(est, ptr, size)
  end

  # C: picoruby-machine/src/heap.c picorb_heap_free
  def __fpga_picorb_heap_free(ptr)
    est = __fpga_image(1105) # L:IMG_est_heap
    return if est == 0 || ptr == 0
    __fpga_est_free(est, ptr)
  end

  # gc.c の mrb_realloc_simple が呼ぶ確保の関数 (MRB_API の mrb_basic_alloc_func を picoruby-machine が定める)
  # C: picoruby-machine/src/mruby/alloc.c mrb_basic_alloc_func
  def __fpga_basic_alloc_func(ptr, size)
    if size == 0
      __fpga_picorb_heap_free(ptr)
      return 0
    end
    __fpga_picorb_heap_realloc(ptr, size)
  end
end
