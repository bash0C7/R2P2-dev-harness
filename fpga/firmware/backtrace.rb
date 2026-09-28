# firmware: backtrace (mruby の src/backtrace.c)、irep の debug 情報 (src/debug.c と src/load.c の read_section_debug)。
# debug 情報は .mrb の DBG の section から読む (mrbc -g。host の picoruby が .rb を読む時と同じ情報)。
# firmware の helper (名前が __fpga_ のメソッド) と罠のフレームは C に無いので、ci を辿る時に越える (D41)
class Object
  # .mrb の section を順に見て、DBG があれば一番外の irep から debug 情報を読む
  # C: src/load.c read_irep
  def __fpga_load_sections(blob, irep)
    sec = blob + 20 # rite_binary_header
    while true
      if __fpga_ld8(sec) == 68 && __fpga_ld8(sec + 1) == 66 && __fpga_ld8(sec + 2) == 71 && __fpga_ld8(sec + 3) == 0 # RITE_SECTION_DEBUG_IDENT "DBG\0"
        __fpga_read_section_debug(sec, irep)
      elsif __fpga_ld8(sec) == 69 && __fpga_ld8(sec + 1) == 78 && __fpga_ld8(sec + 2) == 68 && __fpga_ld8(sec + 3) == 0 # RITE_BINARY_EOF "END\0"
        return
      end
      sec += __fpga_u32(sec + 4) # section_size
    end
  end

  # C: src/load.c read_section_debug
  def __fpga_read_section_debug(start, irep)
    bin = start + 8 # rite_section_debug_header
    filenames_len = __fpga_u16(bin)
    bin += 2
    filenames = __fpga_temp_alloc((filenames_len > 0 ? filenames_len : 1) * 4) # mrb_str_new の中身 (C も String に置く)
    i = 0
    while i < filenames_len
      f_len = __fpga_u16(bin)
      bin += 2
      __fpga_st32(filenames + i * 4, __fpga_intern(bin, f_len)) # mrb_intern_static (名前は .mrb の中を指す)
      bin += f_len
      i += 1
    end
    cur = __fpga_temp_alloc(8) # C の局所変数 bin を指す番地の代わり (D84)
    __fpga_st32(cur, bin)
    __fpga_read_debug_record(cur, irep, filenames, filenames_len)
    __fpga_halt unless __fpga_ld32(cur) - start == __fpga_u32(start + 4) # MRB_DUMP_GENERAL_FAILURE
  end

  # cur (8 バイトの領域) の番地から irep の debug 情報を1つ読み (子も)、cur を進める
  # C: src/load.c read_debug_record
  def __fpga_read_debug_record(cur, irep, filenames, filenames_len)
    start = __fpga_ld32(cur)
    bin = start
    __fpga_halt unless __fpga_ld32(irep + 44) == 0 # L:I_DEBUG MRB_DUMP_INVALID_IREP
    debug = __fpga_calloc(1, 12) # L:DI_SIZE
    __fpga_st32(irep + 44, debug) # L:I_DEBUG
    __fpga_st32(debug + 0, __fpga_ld32(irep + 4)) # L:DI_PC_COUNT L:I_ILEN
    record_size = __fpga_u32(bin)
    bin += 4
    flen = __fpga_u16(bin)
    bin += 2
    __fpga_st32(debug + 4, flen) # L:DI_FLEN
    files = __fpga_calloc(flen > 0 ? flen : 1, 4)
    __fpga_st32(debug + 8, files) # L:DI_FILES
    f_idx = 0
    while f_idx < flen
      file = __fpga_calloc(1, 20) # L:DF_SIZE
      __fpga_st32(files + f_idx * 4, file)
      __fpga_st32(file + 0, __fpga_u32(bin)) # L:DF_START_POS
      bin += 4
      filename_idx = __fpga_u16(bin)
      bin += 2
      __fpga_halt if filename_idx >= filenames_len # MRB_DUMP_GENERAL_FAILURE
      __fpga_st32(file + 4, __fpga_ld32(filenames + filename_idx * 4)) # L:DF_FILENAME
      count = __fpga_u32(bin)
      bin += 4
      __fpga_st32(file + 8, count) # L:DF_COUNT
      type = __fpga_ld8(bin)
      bin += 1
      __fpga_st32(file + 12, type) # L:DF_TYPE
      if type == 0 # mrb_debug_line_ary
        ary = __fpga_malloc((count > 0 ? count : 1) * 2)
        l = 0
        while l < count
          v = __fpga_u16(bin)
          __fpga_st8(ary + l * 2, __fpga_and(v, 255)) # uint16_t (little endian)
          __fpga_st8(ary + l * 2 + 1, __fpga_shr(v, 8))
          bin += 2
          l += 1
        end
        __fpga_st32(file + 16, ary) # L:DF_LINES
      elsif type == 1 # mrb_debug_line_flat_map
        flat_map = __fpga_calloc(count > 0 ? count : 1, 8) # mrb_irep_debug_info_line {start_pos, line}
        l = 0
        while l < count
          __fpga_st32(flat_map + l * 8, __fpga_u32(bin))
          __fpga_st32(flat_map + l * 8 + 4, __fpga_u16(bin + 4))
          bin += 6
          l += 1
        end
        __fpga_st32(file + 16, flat_map) # L:DF_LINES
      elsif type == 2 # mrb_debug_line_packed_map (C は写す。ここは .mrb の中を指す、iseq と同じ)
        __fpga_st32(file + 16, bin) # L:DF_LINES
        bin += count
      else
        __fpga_halt # MRB_DUMP_GENERAL_FAILURE
      end
      f_idx += 1
    end
    __fpga_halt unless record_size == bin - start # MRB_DUMP_GENERAL_FAILURE
    __fpga_st32(cur, bin)
    rlen = __fpga_ld32(irep + 32) # L:I_RLEN
    reps = __fpga_ld32(irep + 28) # L:I_REPS
    i = 0
    while i < rlen
      __fpga_read_debug_record(cur, __fpga_ld32(reps + i * 4), filenames, filenames_len)
      i += 1
    end
  end

  # C: src/debug.c get_file
  def __fpga_debug_get_file(info, pc)
    return 0 if pc >= __fpga_ld32(info + 0) # L:DI_PC_COUNT
    files = __fpga_ld32(info + 8) # L:DI_FILES
    ret = 0
    count = __fpga_ld32(info + 4) # L:DI_FLEN
    while count > 0
      step = count / 2
      it = ret + step
      if pc >= __fpga_ld32(__fpga_ld32(files + it * 4) + 0) # L:DF_START_POS
        ret = it + 1
        count -= step + 1
      else
        count = step
      end
    end
    __fpga_ld32(files + (ret - 1) * 4)
  end

  # C: src/debug.c mrb_packed_int_decode
  def __fpga_packed_int_decode(cur)
    p = __fpga_ld32(cur)
    n = 0
    shift = 0
    while true
      b = __fpga_ld8(p)
      p += 1
      n += __fpga_shl(__fpga_and(b, 127), shift)
      shift += 7
      break unless shift < 32 && b >= 128
    end
    __fpga_st32(cur, p)
    __fpga_and(n, 4294967295)
  end

  # C: src/debug.c debug_get_line
  def __fpga_debug_get_line(f, pc)
    return -1 if f == 0
    return -1 unless __fpga_ld32(f + 12) == 2 # L:DF_TYPE mrb_debug_line_packed_map のほかは -1
    cur = __fpga_temp_alloc(8) # C の局所変数 p を指す番地の代わり (D84)
    p = __fpga_ld32(f + 16) # L:DF_LINES
    pend = p + __fpga_ld32(f + 8) # L:DF_COUNT
    __fpga_st32(cur, p)
    pos = 0
    line = 0
    while __fpga_ld32(cur) < pend
      pos = __fpga_and(pos + __fpga_packed_int_decode(cur), 4294967295) # uint32_t
      line_diff = __fpga_packed_int_decode(cur)
      break if pc < pos
      line = __fpga_and(line + line_diff, 4294967295) # uint32_t (前の行へ戻る差は桁あふれで引く)
    end
    line
  end

  # decode_location (backtrace.c) の "file:line" まで。場所が分からなければ nil (mrb_debug_get_position の FALSE)
  # C: src/debug.c mrb_debug_get_position
  def __fpga_debug_position(irep, pc)
    debug = __fpga_ld32(irep + 44) # L:I_DEBUG
    return nil unless pc >= 0 && pc < __fpga_ld32(irep + 4) && debug > 0 # L:I_ILEN
    f = __fpga_debug_get_file(debug, pc)
    lineno = __fpga_debug_get_line(f, pc)
    return nil unless lineno > 0
    __fpga_format("%s:%d", [__fpga_sym_str(__fpga_ld32(f + 4)), lineno]) # L:DF_FILENAME
  end

  # firmware だけのフレーム: 名前が __fpga_ のメソッド (helper と罠)。C には ci が無い (D41)
  # C: none (D41)
  def __fpga_bt_hidden_p(mid)
    return false if mid >= __fpga_image(1077) # L:IMG_symcapa
    tab = __fpga_image(1076) # L:IMG_symtbl
    p = __fpga_ld32(tab + mid * 8)
    return false if __fpga_ld32(tab + mid * 8 + 4) < 7
    __fpga_ld8(p) == 95 && __fpga_ld8(p + 1) == 95 && __fpga_ld8(p + 2) == 102 && __fpga_ld8(p + 3) == 112 &&
      __fpga_ld8(p + 4) == 103 && __fpga_ld8(p + 5) == 97 && __fpga_ld8(p + 6) == 95 # "__fpga_"
  end

  # ROM の Proc (firmware) は C の関数のフレーム (MRB_PROC_CFUNC_P)
  # C: include/mruby/proc.h MRB_PROC_CFUNC_P (D41)
  def __fpga_bt_cfunc_p(pr)
    pr < __fpga_image(1085) || __fpga_and(__fpga_ld32(pr + 24), 3) > 0 # L:IMG_heap_start L:P_FLAGS PROC_IREP でない
  end

  # 記憶の ci の pc (次の命令の番地) から、irep の中の今の命令の位置 (&ci->pc[-1] - irep->iseq)
  # C: src/backtrace.c pack_backtrace
  def __fpga_bt_idx(ci, irep)
    __fpga_ld32(ci + 20) - 1 - __fpga_ld32(irep + 8) # L:CI_PC L:I_ISEQ
  end

  # C: src/backtrace.c pack_backtrace
  def __fpga_pack_backtrace(ci, ptr)
    base = __fpga_cibase
    n = 0
    while ci >= base
      mid = __fpga_ld32(ci + 4) # L:CI_MID
      pr = __fpga_ld32(ci + 8) # L:CI_PROC
      irep = 0
      idx = 0
      keep = __fpga_bt_hidden_p(mid) ? false : true
      if keep && pr > 0 && __fpga_bt_cfunc_p(pr) == false
        irep = __fpga_ld32(pr + 8) # L:P_BODY
        keep = __fpga_ld32(irep + 44) > 0 && __fpga_ld32(ci + 20) > 0 # L:I_DEBUG L:CI_PC
        idx = __fpga_bt_idx(ci, irep)
      elsif keep
        keep = mid > 0
        j = ci - 64 # L:CI_SIZE
        while keep && j >= base
          jp = __fpga_ld32(j + 8) # L:CI_PROC
          if jp > 0 && __fpga_bt_cfunc_p(jp) == false
            jr = __fpga_ld32(jp + 8) # L:P_BODY
            if __fpga_ld32(jr + 44) > 0 && __fpga_ld32(j + 20) > 0 # L:I_DEBUG L:CI_PC
              irep = jr
              idx = __fpga_bt_idx(j, jr)
              break
            end
          end
          j -= 64 # L:CI_SIZE
        end
      end
      if keep
        loc = ptr + n * 12 # L:LOC_SIZE
        __fpga_st32(loc + 0, mid) # L:LOC_MID
        __fpga_st32(loc + 4, idx) # L:LOC_IDX
        __fpga_st32(loc + 8, irep) # L:LOC_IREP
        n += 1
      end
      ci -= 64 # L:CI_SIZE
    end
    n
  end

  # C: src/backtrace.c packed_backtrace
  def __fpga_packed_backtrace
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI
    len = (ci - __fpga_cibase) / 64 + 1 # L:CI_SIZE
    bt = __fpga_slot(0, 28) # L:TT_BACKTRACE MRB_OBJ_ALLOC(mrb, MRB_TT_BACKTRACE, NULL)
    ptr = __fpga_malloc(len * 12) # L:LOC_SIZE
    __fpga_st32(bt + 12, ptr) # L:BT_LOCATIONS
    __fpga_st32(bt + 8, __fpga_pack_backtrace(ci, ptr)) # L:BT_LEN
    bt
  end

  # C: src/backtrace.c mrb_keep_backtrace
  def __fpga_keep_backtrace(exc)
    return if __fpga_ld32(__fpga_addr(exc) + 12) > 0 # L:EX_BACKTRACE
    __fpga_st32(__fpga_addr(exc) + 12, __fpga_packed_backtrace) # L:EX_BACKTRACE store_backtrace
  end

  # C: src/backtrace.c decode_location
  def __fpga_decode_location(loc)
    irep = __fpga_ld32(loc + 8) # L:LOC_IREP
    return "(unknown):0" if irep == 0 # UNKNOWN_LOCATION
    btline = __fpga_debug_position(irep, __fpga_ld32(loc + 4)) # L:LOC_IDX
    return "(unknown):0" if __fpga_tag(btline) == 0 # L:TAG_NIL UNKNOWN_LOCATION
    mid = __fpga_ld32(loc + 0) # L:LOC_MID
    if mid > 0
      __fpga_str_cat_str(btline, ":in ")
      __fpga_str_cat_str(btline, __fpga_sym_str(mid)) # mrb_sym_name
    end
    btline
  end

  # C: src/backtrace.c mrb_unpack_backtrace
  def __fpga_unpack_backtrace(bt)
    return [] if bt == 0
    return __fpga_obj(bt) if __fpga_tt(bt) == 17 # L:TT_ARRAY
    n = __fpga_ld32(bt + 8) # L:BT_LEN
    loc = __fpga_ld32(bt + 12) # L:BT_LOCATIONS
    ary = []
    i = 0
    while i < n
      ary.__fpga_push1(__fpga_decode_location(loc + i * 12)) # L:LOC_SIZE
      i += 1
    end
    ary
  end

  # 捕まらなかった例外を出して止まる (mrb_print_error の mrb_print_backtrace)
  # C: src/backtrace.c print_backtrace
  def __fpga_print_error
    exc = __fpga_ld32(3 * 4) # L:IMG_exc L:WORD
    ptr = __fpga_ld32(exc + 12) # L:EX_BACKTRACE
    n = 0
    if ptr > 0
      n = __fpga_tt(ptr) == 17 ? __fpga_alen(__fpga_obj(ptr)) : __fpga_ld32(ptr + 8) # L:TT_ARRAY L:BT_LEN
    end
    if n > 0
      __fpga_write_str("trace (most recent call last):\n")
      i = n - 1
      while i > 0
        btline = __fpga_bt_line(ptr, i)
        if __fpga_tag(btline) == 7 && __fpga_tt(__fpga_addr(btline)) == 18 # L:TAG_OBJ L:TT_STRING
          __fpga_write_str(__fpga_format("\t[%d] ", [i]))
          __fpga_write_str(btline)
          __fpga_putc(10)
        end
        i -= 1
      end
      btline = __fpga_bt_line(ptr, 0)
      if __fpga_tag(btline) == 7 && __fpga_tt(__fpga_addr(btline)) == 18 # L:TAG_OBJ L:TT_STRING
        __fpga_write_str(btline)
        __fpga_write_str(": ")
      end
    else
      __fpga_write_str("(unknown):0: ") # UNKNOWN_LOCATION
    end
    if exc == __fpga_image(1080) # L:IMG_nomem_err
      __fpga_write_str("Out of memory (NoMemoryError)\n")
    else
      __fpga_write_str(__fpga_exc_get_output(__fpga_obj(exc)))
      __fpga_putc(10)
    end
    __fpga_halt
  end

  # print_backtrace の 1 行 (配列なら要素、packed なら decode_location)
  # C: src/backtrace.c print_backtrace
  def __fpga_bt_line(ptr, i)
    return __fpga_aref(__fpga_obj(ptr), i) if __fpga_tt(ptr) == 17 # L:TT_ARRAY
    __fpga_decode_location(__fpga_ld32(ptr + 12) + i * 12) # L:BT_LOCATIONS L:LOC_SIZE
  end
end
