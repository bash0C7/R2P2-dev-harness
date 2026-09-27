# firmware: 例外 (mruby の src/error.c、src/kernel.c の raise、src/vm.c の L_RAISE と L_RETURN の巻き戻し、OP_EXCEPT / RESCUE /
# RAISEIF / JMPUW / BREAK / RETURN_BLK、計画 S4-2)。
# 巻き戻しは記憶の mrb_callinfo を辿って決め、回路の primitive __fpga_unwind (上の ci を捨てて ci の pc へ) と
# __fpga_unwind_ret (上の ci を捨てて ci から値を返す) で飛ぶ。firmware のフレームは catch handler を持たないので、辿る時にそのまま越える
class Object
  # --- mrb->exc (mrb_state の exc の語)
  # C: src/error.c mrb_exc_set
  def __fpga_exc_set(v)
    __fpga_st32(3 * 4, __fpga_tag(v) == 0 ? 0 : __fpga_addr(v)) # L:IMG_exc L:WORD
  end

  # C: src/error.c mrb_exc_new_str
  def __fpga_exc_new_str(c, str)
    e = __fpga_obj(__fpga_slot(__fpga_addr(c), 14)) # L:TT_EXCEPTION
    __fpga_exc_mesg_set(e, str)
    e
  end

  # C: src/error.c mrb_exc_mesg_set
  def __fpga_exc_mesg_set(e, mesg)
    mesg = __fpga_obj_as_string(mesg) unless __fpga_tag(mesg) == 7 && __fpga_tt(__fpga_addr(mesg)) == 18 # L:TAG_OBJ L:TT_STRING
    __fpga_st32(__fpga_addr(e) + 8, __fpga_addr(mesg)) # L:EX_MESG
  end

  # C: src/error.c mrb_exc_mesg_get
  def __fpga_exc_mesg_get(e)
    m = __fpga_ld32(__fpga_addr(e) + 8) # L:EX_MESG
    m == 0 ? nil : __fpga_obj(m)
  end

  # C: src/error.c mrb_exc_get_output
  def __fpga_exc_get_output(exc)
    cname = __fpga_mod_to_s(__fpga_obj_class(exc))
    mesg = __fpga_exc_mesg_get(exc)
    return cname if __fpga_tag(mesg) == 0 || __fpga_ld32(__fpga_addr(mesg) + 8) == 0 # L:S_LEN
    __fpga_format("%v (%v)", [mesg, cname])
  end

  # C: src/error.c mrb_exc_raise
  def __fpga_exc_raise(exc)
    if __fpga_break_p(exc)
      __fpga_st32(3 * 4, __fpga_addr(exc)) # L:IMG_exc L:WORD
    else
      __fpga_raise(TypeError, "exception object expected") unless __fpga_tag(exc) == 7 && __fpga_tt(__fpga_addr(exc)) == 14 # L:TAG_OBJ L:TT_EXCEPTION
      __fpga_exc_set(exc)
    end
    __fpga_throw
  end

  # C: src/error.c mrb_raise
  def __fpga_raise(c, msg)
    __fpga_exc_raise(__fpga_exc_new_str(c, msg))
  end

  # C: src/error.c mrb_raisef
  def __fpga_raisef(c, fmt, args)
    __fpga_exc_raise(__fpga_exc_new_str(c, __fpga_format(fmt, args)))
  end

  # C: src/error.c mrb_name_error
  def __fpga_name_error(sym, fmt, args)
    exc = __fpga_exc_new_str(NameError, __fpga_format(fmt, args))
    __fpga_iv_set(exc, :@name, __fpga_mkval(4, sym)) # L:TAG_SYM
    __fpga_exc_raise(exc)
  end

  # C: src/error.c mrb_no_method_error
  def __fpga_no_method_error(sym, margs, fmt, args)
    exc = __fpga_exc_new_str(NoMethodError, __fpga_format(fmt, args))
    __fpga_iv_set(exc, :@name, __fpga_mkval(4, sym)) # L:TAG_SYM
    __fpga_iv_set(exc, :@args, margs)
    __fpga_exc_raise(exc)
  end

  # C: src/class.c mrb_method_search
  def __fpga_method_search_error(c, mid)
    __fpga_name_error(mid, "undefined method '%n' for class %C", [__fpga_mkval(4, mid), __fpga_obj(c)]) # L:TAG_SYM
  end

  # vm.c の argnum_error (ENTER の引数の数の違い): 期待は 1 つの数。firmware の def (像の中の Proc) は C の関数の写しなので、
  # mruby が C の関数の前にする check_argument_count の mrb_argnum_error の形 (min..max、min+)
  # C: src/vm.c argnum_error
  def __fpga_op_argc(given, min, max)
    return __fpga_raise_argnum(given, min, max) if __fpga_proc < __fpga_image(35) # L:IMG_heap_start
    __fpga_raisef(ArgumentError, "wrong number of arguments (given %i, expected %i)", [given, min])
  end

  # 呼び出しの深さが MRB_CALL_LEVEL_MAX に届いた (回路の罠)
  # C: src/vm.c cipush
  def __fpga_op_stack_err
    __fpga_exc_raise(__fpga_obj(__fpga_image(31))) # L:IMG_stack_err
  end

  # OP_BLKPUSH の遅い道: ブロックが無い
  # C: src/vm.c vm_op_blkpush
  def __fpga_op_BLKPUSH(a, b, c)
    __fpga_raise(LocalJumpError, "unexpected yield")
  end

  # 起動の時に作る例外の物 (mrb_init_exception の stack_err と nomem_err)
  # C: src/error.c mrb_init_exception
  def __fpga_init_exception
    __fpga_st32(31 * 4, __fpga_addr(__fpga_exc_new_str(SystemStackError, "stack level too deep"))) # L:IMG_stack_err L:WORD
    __fpga_st32(30 * 4, __fpga_addr(__fpga_exc_new_str(NoMemoryError, "Out of memory"))) # L:IMG_nomem_err L:WORD
  end

  # C: src/vm.c L_INT_OVERFLOW
  def __fpga_op_overflow(a, op)
    __fpga_raise(RangeError, "integer overflow")
  end

  # C: src/numeric.c mrb_int_zerodiv
  def __fpga_op_zerodiv(a)
    __fpga_raise(ZeroDivisionError, "divided by 0")
  end

  # C: src/error.c mrb_make_exception
  def __fpga_make_exception(exc, mesg)
    if __fpga_tag(exc) == 7 && __fpga_class_p(__fpga_addr(exc)) # L:TAG_OBJ mrb_class_p
      exc = __fpga_tag(mesg) == 0 ? exc.new : exc.new(mesg)
    elsif __fpga_tag(exc) == 7 && __fpga_tt(__fpga_addr(exc)) == 14 # L:TAG_OBJ L:TT_EXCEPTION
      unless __fpga_tag(mesg) == 0 # L:TAG_NIL
        exc = __fpga_obj_clone(exc)
        __fpga_exc_mesg_set(exc, mesg)
      end
    else
      __fpga_raise(TypeError, "exception class/object expected")
    end
    __fpga_raise(Exception, "exception object expected") unless __fpga_tag(exc) == 7 && __fpga_tt(__fpga_addr(exc)) == 14 # L:TAG_OBJ L:TT_EXCEPTION
    exc
  end

  # --- mrb_vformat: %d %i (数)、%n (シンボル)、%s %v %S (to_s)、%C %t %T (クラス)、%Y、! (inspect)、%%
  # C: src/error.c mrb_vformat
  def __fpga_format(fmt, args)
    p = __fpga_ld32(__fpga_addr(fmt) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(fmt) + 8) # L:S_LEN
    result = __fpga_str_new(p, 0)
    b = 0
    k = 0
    n = 0
    while k < len
      ch = __fpga_ld8(p + k)
      k += 1
      next unless ch == 37 # '%'
      __fpga_str_cat(result, p + b, k - 1 - b)
      inspect = false
      ch = __fpga_ld8(p + k)
      if ch == 33 # '!'
        inspect = true
        k += 1
        ch = __fpga_ld8(p + k)
      end
      k += 1
      if ch == 37 # '%%'
        __fpga_str_cat(result, p + k - 1, 1)
      else
        obj = __fpga_aref(args, n)
        n += 1
        if ch == 67 || ch == 116 || ch == 84 # 'C' 't' 'T'
          obj = __fpga_obj_class(obj) if ch == 84
          obj = __fpga_class_of(obj) if ch == 116 # mrb_class
        elsif ch == 89 # 'Y'
          if __fpga_tag(obj) <= 2 # L:TAG_TRUE nil、false、true
            inspect = true
          else
            obj = __fpga_obj_class(obj)
          end
        end
        __fpga_str_cat_str(result, inspect ? __fpga_inspect(obj) : __fpga_obj_as_string(obj))
      end
      b = k
    end
    __fpga_str_cat(result, p + b, len - b)
    result
  end

  # C: src/object.c mrb_inspect
  def __fpga_inspect(v)
    s = v.inspect
    return s if __fpga_tag(s) == 7 && __fpga_tt(__fpga_addr(s)) == 18 # L:TAG_OBJ L:TT_STRING
    __fpga_obj_as_string(v)
  end

  # C: src/string.c mrb_obj_as_string
  def __fpga_obj_as_string(v)
    return v if __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 18 # L:TAG_OBJ L:TT_STRING
    return __fpga_mod_to_s(v) if __fpga_tag(v) == 7 && __fpga_class_p(__fpga_addr(v)) # L:TAG_OBJ
    s = v.to_s # mrb_type_convert
    __fpga_raise(TypeError, "can't convert to String") unless __fpga_tag(s) == 7 && __fpga_tt(__fpga_addr(s)) == 18 # L:TAG_OBJ L:TT_STRING
    s
  end

  # 名前の道 (class.c の mrb_class_path)。名前は C_NAME と C_OUTER から作る (mruby は __classname__ の iv に持つ、D04)。無名は nil
  # C: src/class.c mrb_class_path (D04)
  def __fpga_class_path(c)
    id = __fpga_ld32(c + 24) # L:C_NAME
    return nil if id == 0
    name = __fpga_sym_str(id)
    outer = __fpga_ld32(c + 28) # L:C_OUTER
    return name if outer == 0 || outer == __fpga_image(5) # L:IMG_object_class
    op = __fpga_class_path(outer)
    return nil if __fpga_tag(op) == 0
    __fpga_str_cat_str(op, "::")
    __fpga_str_cat_str(op, name)
  end

  # 特異クラスは "#<Class:付いている物>"、ほかは class_name_str (名前の道、無名なら "#<Class:0x..>")
  # C: src/class.c mrb_mod_to_s
  def __fpga_mod_to_s(klass)
    c = __fpga_addr(klass)
    if __fpga_tt(c) == 11 # L:TT_SCLASS
      v = __fpga_ld32(c + 28) # L:C_OUTER __attached__
      str = "#<Class:"
      att = __fpga_obj(v)
      __fpga_str_cat_str(str, __fpga_class_p(v) ? __fpga_inspect(att) : __fpga_any_to_s(att)) # class_ptr_p
      return __fpga_str_cat_str(str, ">")
    end
    __fpga_class_name_str(c)
  end

  # C: src/class.c class_name_str
  def __fpga_class_name_str(c)
    path = __fpga_class_path(c)
    return path unless __fpga_tag(path) == 0 # L:TAG_NIL
    path = __fpga_tt(c) == 10 ? "#<Module:" : "#<Class:" # L:TT_MODULE
    __fpga_str_cat_str(path, __fpga_ptr_to_str(c))
    __fpga_str_cat_str(path, ">")
  end

  # --- catch handler の表 (irep.h の mrb_irep_catch_handler、13 バイト)。xpc は次の命令の位置 (vm.c と同じく pc > begin && pc <= end)
  # C: src/vm.c catch_handler_find
  def __fpga_catch_find(ir, xpc, filter)
    return 0 unless xpc > -1 && xpc <= __fpga_ld32(ir + 4) # L:I_ILEN
    tab = __fpga_ld32(ir + 36) # L:I_CATCH
    cnt = __fpga_ld32(ir + 40) # L:I_CLEN
    while cnt > 0
      cnt -= 1
      e = tab + cnt * 13 # L:CATCH_ENTRY
      if __fpga_and(__fpga_shl(1, __fpga_ld8(e)), filter) > 0 && xpc > __fpga_u32(e + 1) && xpc <= __fpga_u32(e + 5)
        return e
      end
    end
    0
  end

  # ci の catch handler (L_RAISE と UNWIND_ENSURE の条件: Proc があり、C の関数でなく、irep に catch がある)。無ければ 0
  # C: src/vm.c UNWIND_ENSURE
  def __fpga_ci_catch(ci, filter)
    pr = __fpga_ld32(ci + 8) # L:CI_PROC
    return 0 if pr == 0 || __fpga_and(__fpga_ld32(pr + 24), 3) > 0 # L:P_FLAGS MRB_PROC_CFUNC_P (primitive と attr)
    ir = __fpga_ld32(pr + 8) # L:P_BODY
    return 0 if __fpga_ld32(ir + 40) < 1 # L:I_CLEN
    __fpga_catch_find(ir, __fpga_ld32(ci + 20) - __fpga_ld32(ir + 8), filter) # L:CI_PC L:I_ISEQ
  end

  # C: src/vm.c catch_handler_find
  def __fpga_catch_target(ci, ch)
    __fpga_u32(ch + 9)
  end

  # C: src/vm.c OP_RAISEIF
  def __fpga_cibase
    __fpga_ld32(__fpga_image(0) + 16) # L:IMG_c L:CTX_CIBASE
  end

  # L_RAISE: 今の ci から、catch handler (rescue か ensure) のある ci を探して飛ぶ。無ければ cipop。
  # __fpga_run のフレーム (vm.c の CINFO_SKIP に当たる) を出る時は、exc を残してそこから nil を返す
  # C: src/vm.c L_RAISE
  def __fpga_throw
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI
    base = __fpga_cibase
    while true
      ch = __fpga_ci_catch(ci, 3) # MRB_CATCH_FILTER_ALL
      return __fpga_unwind(ci, __fpga_catch_target(ci, ch)) if ch > 0
      return __fpga_unwind_ret(ci, nil) if __fpga_ld8(ci + 3) == 5 # L:CI_CONT L:CONT_RUN
      __fpga_halt if ci == base # 起動のフレームまで捕まらない (mrb_print_error は S5)
      ci -= 64 # L:CI_SIZE cipop
    end
  end

  # C: src/vm.c OP_EXCEPT
  def __fpga_op_EXCEPT(a, b, c)
    e = __fpga_ld32(3 * 4) # L:IMG_exc L:WORD
    __fpga_st32(3 * 4, 0) if e > 0 # L:IMG_exc L:WORD
    __fpga_setreg(a, e == 0 ? nil : __fpga_obj(e))
  end

  # C: src/vm.c OP_RESCUE
  def __fpga_op_RESCUE(a, b, c)
    exc = __fpga_reg(a)
    e = __fpga_reg(b)
    t = __fpga_tag(e) == 7 ? __fpga_tt(__fpga_addr(e)) : 0 # L:TAG_OBJ
    __fpga_raise(TypeError, "class or module required for rescue clause") unless t == 9 || t == 10 # L:TT_CLASS L:TT_MODULE
    __fpga_setreg(b, __fpga_break_p(exc) ? false : __fpga_kind_of(exc, e))
  end

  # C: include/mruby/value.h mrb_break_p
  def __fpga_break_p(v)
    __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 24 # L:TAG_OBJ L:TT_BREAK
  end

  # C: src/vm.c OP_RAISEIF
  def __fpga_op_RAISEIF(a, b, c)
    exc = __fpga_reg(a)
    if __fpga_tag(exc) == 0 # L:TAG_NIL mrb_nil_p (break の物は == に応じない)
      __fpga_st32(3 * 4, 0) # L:IMG_exc L:WORD
    elsif __fpga_break_p(exc)
      __fpga_st32(3 * 4, __fpga_addr(exc)) # L:IMG_exc L:WORD
      __fpga_break_dispatch(__fpga_addr(exc))
    else
      __fpga_exc_set(exc)
      __fpga_throw
    end
  end

  # L_BREAK: break の物の tag の CHECKPOINT_RESTORE へ
  # C: src/vm.c L_BREAK
  def __fpga_break_dispatch(brk)
    tag = __fpga_and(__fpga_shr(__fpga_ld32(brk + 4), 8 + 12), 7) # L:H_FLAGS L:RBREAK_TAG_BIT_OFF L:H_FLAGS_SHIFT
    ci = __fpga_ci
    if tag == 1 # L:RBREAK_TAG_JUMP
      __fpga_jump_checkpoint(ci, __fpga_ldv(brk + 16)) # L:BRK_VAL
    else # RBREAK_TAG_BREAK と RBREAK_TAG_STOP: return_ci から値を返す
      rci = __fpga_cibase + __fpga_ld32(brk + 8) * 64 # L:BRK_INDEX L:CI_SIZE
      __fpga_unwinding(ci, rci, __fpga_ldv(brk + 16), tag) # L:BRK_VAL
    end
  end

  # C: src/vm.c break_new
  def __fpga_break_new(tag, rci, v)
    brk = __fpga_slot(0, __fpga_or(24, __fpga_shl(tag, 8 + 12))) # L:TT_BREAK L:RBREAK_TAG_BIT_OFF L:H_FLAGS_SHIFT
    __fpga_st32(brk + 8, (rci - __fpga_cibase) / 64) # L:BRK_INDEX L:CI_SIZE
    __fpga_stv(brk + 16, v) # L:BRK_VAL
    brk
  end

  # C: src/vm.c prepare_tagged_break
  def __fpga_prepare_tagged_break(tag, rci, v)
    e = __fpga_ld32(3 * 4) # L:IMG_exc L:WORD
    if e > 0 && __fpga_tt(e) == 24 # L:TT_BREAK break_tag_p
      f = __fpga_ld32(e + 4) # L:H_FLAGS
      __fpga_st32(e + 4, __fpga_or(f - __fpga_and(f, __fpga_shl(7, 8 + 12)), __fpga_shl(tag, 8 + 12))) # L:RBREAK_TAG_BIT_OFF L:H_FLAGS_SHIFT
    else
      __fpga_st32(3 * 4, __fpga_break_new(tag, rci, v)) # L:IMG_exc L:WORD
    end
  end

  # L_RETURN の CHECKPOINT_MAIN(RBREAK_TAG_BREAK): ci から return_ci まで、ensure を見ながら cipop し、return_ci から v を返す。
  # ensure があれば tag 付きの break を投げて (THROW_TAGGED_BREAK) その handler へ飛ぶ
  # C: src/vm.c L_RETURN
  def __fpga_unwinding(ci, rci, v, tag)
    while true
      ch = __fpga_ci_catch(ci, 2) # MRB_CATCH_FILTER_ENSURE
      if ch > 0
        __fpga_prepare_tagged_break(tag, rci, v)
        return __fpga_unwind(ci, __fpga_catch_target(ci, ch)) # L_CATCH_TAGGED_BREAK
      end
      break if ci == rci
      ci -= 64 # L:CI_SIZE cipop (罠のフレーム CINFO_DIRECT は越える)
    end
    __fpga_st32(3 * 4, 0) # L:IMG_exc L:WORD break の物を消す
    __fpga_unwind_ret(rci, v)
  end

  # RETURN 系 (irep に catch がある時だけ回路が罠にする): 今のフレームの ensure を見てから戻る
  # C: src/vm.c OP_RETURN
  def __fpga_op_return(v)
    ci = __fpga_ci
    __fpga_unwinding(ci, ci, v, 0) # L:RBREAK_TAG_BREAK
  end

  # STOP (irep に catch がある時): ensure を見てから、__fpga_run のフレームから nil を返す
  # C: src/vm.c OP_STOP
  def __fpga_op_stop(v)
    ci = __fpga_ci
    __fpga_unwinding(ci, ci, v, 2) # L:RBREAK_TAG_STOP
  end

  # OP_JMPUW: ensure をまたぐ飛び先なら tag JUMP の break を投げる
  # C: src/vm.c OP_JMPUW
  def __fpga_op_JMPUW(a, b, c)
    ci = __fpga_ci
    ir = __fpga_ld32(__fpga_ld32(ci + 8) + 8) # L:CI_PROC L:P_BODY
    a -= 65536 if a >= 32768 # int16_t
    __fpga_jump_checkpoint(ci, __fpga_ld32(ci + 20) - __fpga_ld32(ir + 8) + a) # L:CI_PC L:I_ISEQ
  end

  # OP_JMPUW の CHECKPOINT_MAIN(RBREAK_TAG_JUMP)
  # C: src/vm.c OP_JMPUW
  def __fpga_jump_checkpoint(ci, a)
    ch = __fpga_ci_catch(ci, 2) # MRB_CATCH_FILTER_ENSURE
    if ch > 0 && (a < __fpga_u32(ch + 1) || a > __fpga_u32(ch + 5)) # 同じ handler の中へは飛ばない
      __fpga_prepare_tagged_break(1, ci, a) # L:RBREAK_TAG_JUMP
      return __fpga_unwind(ci, __fpga_catch_target(ci, ch))
    end
    __fpga_st32(3 * 4, 0) # L:IMG_exc L:WORD
    __fpga_unwind(ci, a)
  end

  # OP_BREAK: strict の Proc は return。env のあるブロックは、upper の Proc を ci[-1].proc に持つ ci まで巻き戻してそこから返す
  # C: src/vm.c OP_BREAK
  def __fpga_op_BREAK(a, b, c)
    ci = __fpga_ci
    pr = __fpga_ld32(ci + 8) # L:CI_PROC
    f = __fpga_ld32(pr + 24) # L:P_FLAGS
    return __fpga_op_return(__fpga_reg(a)) if __fpga_and(f, 256) > 0 # L:PROC_STRICT L_OP_RETURN_BODY
    if __fpga_and(f, 512) == 0 && __fpga_and(f, 1024) > 0 && __fpga_ld32(__fpga_ld32(pr + 16) + 12) == __fpga_image(0) # L:PROC_ORPHAN L:PROC_ENVSET L:P_ENV L:E_CXT L:IMG_c
      dst = __fpga_ld32(pr + 12) # L:P_UPPER
      k = ci
      base = __fpga_cibase
      while k > base
        return __fpga_unwinding(ci, k, __fpga_reg(a), 0) if __fpga_ld32(k - 64 + 8) == dst # L:CI_SIZE L:CI_PROC L_UNWINDING L:RBREAK_TAG_BREAK
        k -= 64 # L:CI_SIZE
      end
    end
    __fpga_raise(LocalJumpError, "break from proc-closure")
  end

  # OP_RETURN_BLK (回路は env のある strict でないブロックの時だけ罠にする): top_proc の env を u に持つ ci から返す
  # C: src/vm.c OP_RETURN_BLK
  def __fpga_op_RETURN_BLK(a, b, c)
    ci = __fpga_ci
    env = __fpga_ld32(ci + 24) # L:CI_U
    dst = __fpga_ld32(ci + 8) # L:CI_PROC
    while __fpga_ld32(dst + 12) > 0 # L:P_UPPER top_proc
      break if __fpga_and(__fpga_ld32(dst + 24), 2048 + 256) > 0 # L:P_FLAGS L:PROC_SCOPE L:PROC_STRICT
      env = __fpga_ld32(dst + 16) # L:P_ENV
      dst = __fpga_ld32(dst + 12) # L:P_UPPER
    end
    if __fpga_and(__fpga_ld32(dst + 24), 1024) == 0 || __fpga_ld32(__fpga_ld32(dst + 16) + 12) == __fpga_image(0) # L:P_FLAGS L:PROC_ENVSET L:P_ENV L:E_CXT L:IMG_c
      k = ci
      base = __fpga_cibase
      while k >= base
        return __fpga_unwinding(ci, k, __fpga_reg(a), 0) if __fpga_ld32(k + 24) == env # L:CI_U L_UNWINDING L:RBREAK_TAG_BREAK
        k -= 64 # L:CI_SIZE
      end
    end
    __fpga_raise(LocalJumpError, "unexpected return")
  end

  # OP_ARYPUSH の遅い道: R[a] が Array でない
  # C: src/vm.c OP_ARYPUSH
  def __fpga_op_ARYPUSH(a, b, c)
    __fpga_ensure_array_type(__fpga_reg(a))
  end

  # C: src/object.c mrb_ensure_array_type
  def __fpga_ensure_array_type(v)
    __fpga_raisef(TypeError, "%Y cannot be converted to Array", [v]) unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 17 # L:TAG_OBJ L:TT_ARRAY
    v
  end

  # C: src/object.c mrb_ensure_string_type
  def __fpga_ensure_string_type(v)
    __fpga_raisef(TypeError, "%Y cannot be converted to String", [v]) unless __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 18 # L:TAG_OBJ L:TT_STRING
    v
  end

  # C: src/class.c mrb_obj_class
  def __fpga_obj_class(v)
    __fpga_obj(__fpga_real(__fpga_addr(__fpga_class_of(v))))
  end

  # C: src/object.c mrb_obj_is_kind_of
  def __fpga_kind_of(obj, c)
    k = __fpga_addr(__fpga_class_of(obj))
    t = __fpga_addr(c)
    tm = __fpga_ld32(t + 12) # L:C_MT
    while k > 0
      return true if k == t || (__fpga_tt(k) == 15 && __fpga_ld32(k + 12) == tm) # L:TT_ICLASS L:C_MT iclass は module の表を共有する
      k = __fpga_ld32(k + 8) # L:C_SUPER
    end
    false
  end
end

class Exception
  # C: src/class.c mrb_instance_new
  def self.exception(*args, &blk)
    o = __fpga_instance_alloc(self)
    __fpga_sendv(o, :initialize, args, blk, true)
    o
  end

  # C: src/error.c exc_exception
  def exception(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    return self if __fpga_alen(args) == 0
    a = __fpga_aref(args, 0)
    return self if __fpga_tag(a) == __fpga_tag(self) && __fpga_int(a) == __fpga_int(self) # mrb_obj_equal
    exc = __fpga_obj_clone(self)
    __fpga_exc_mesg_set(exc, a)
    exc
  end

  # C: src/error.c exc_initialize
  def initialize(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    __fpga_exc_mesg_set(self, __fpga_aref(args, 0)) if __fpga_alen(args) >= 1
    self
  end

  # C: src/error.c exc_to_s
  def to_s
    mesg = __fpga_exc_mesg_get(self)
    return __fpga_mod_to_s(__fpga_obj_class(self)) unless __fpga_tag(mesg) == 7 && __fpga_tt(__fpga_addr(mesg)) == 18 # L:TAG_OBJ L:TT_STRING mrb_obj_classname
    mesg
  end

  alias message to_s # error.c は to_s と message に同じ関数 exc_to_s を置く

  # C: src/error.c mrb_exc_inspect
  def inspect
    cname = __fpga_mod_to_s(__fpga_obj_class(self))
    mesg = __fpga_exc_mesg_get(self)
    return cname if __fpga_tag(mesg) == 0 || __fpga_ld32(__fpga_addr(mesg) + 8) == 0 # L:S_LEN
    __fpga_format("#<%v: %v>", [cname, mesg])
  end

  # 残した backtrace (mrb_keep_backtrace は irep の debug 情報が要るので S5。それまで nil か set_backtrace の配列)
  # C: src/backtrace.c mrb_exc_backtrace (D41)
  def backtrace
    bt = __fpga_ld32(__fpga_addr(self) + 12) # L:EX_BACKTRACE
    bt == 0 ? nil : __fpga_obj(bt)
  end

  # C: src/error.c exc_set_backtrace
  def set_backtrace(bt)
    ok = __fpga_tag(bt) == 7 && __fpga_tt(__fpga_addr(bt)) == 17 # L:TAG_OBJ L:TT_ARRAY
    k = 0
    while ok && k < __fpga_alen(bt)
      v = __fpga_aref(bt, k)
      ok = __fpga_tag(v) == 7 && __fpga_tt(__fpga_addr(v)) == 18 # L:TAG_OBJ L:TT_STRING
      k += 1
    end
    __fpga_raise(TypeError, "backtrace must be Array of String") unless ok
    __fpga_st32(__fpga_addr(self) + 12, __fpga_addr(bt)) # L:EX_BACKTRACE
    bt
  end
end

module Kernel
  # raise (kernel.c の mrb_f_raise): 引数無しは $! を上げ直す (無ければ RuntimeError "")、文字列 1 つは RuntimeError
  # C: src/kernel.c mrb_f_raise
  def raise(*args)
    __fpga_check_argc(args, 0, 2) # MRB_ARGS_OPT(2)
    __fpga_f_raise(args)
  end
end

class Object
  # Kernel#raise と Kernel.raise の本体 (C は同じ関数)
  # C: src/kernel.c mrb_f_raise
  def __fpga_f_raise(args)
    argc = __fpga_alen(args)
    if argc == 0
      exc = $!
      __fpga_exc_raise(exc) unless __fpga_tag(exc) == 0
      __fpga_raise(RuntimeError, "")
    end
    exc = __fpga_aref(args, 0)
    mesg = argc >= 2 ? __fpga_aref(args, 1) : nil
    if argc == 1 && __fpga_tag(exc) == 7 && __fpga_tt(__fpga_addr(exc)) == 18 # L:TAG_OBJ L:TT_STRING
      mesg = exc
      exc = RuntimeError
    end
    __fpga_exc_raise(__fpga_make_exception(exc, mesg))
  end
end

class Module
  # C: src/class.c mrb_mod_to_s
  def to_s
    __fpga_mod_to_s(self)
  end
end
