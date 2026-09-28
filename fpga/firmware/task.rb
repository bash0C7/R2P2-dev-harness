# firmware: mruby-task (mrbgems/mruby-task/src/task.c) の sleep_ms と scheduler の最小 (main task 1 つ、D103) と、
# FPGA の HAL (ports/posix/task_hal.c の形を板のモデルの mmio で、D102)。時刻は全 task が待つ時だけ進む (D100)。
# task の状態は mrb_state.task (layout.rb の IMG_task_*)、task の構造体は layout.rb の TK_*
module Kernel
  # C: mrbgems/mruby-task/src/task.c mrb_f_sleep_ms
  def sleep_ms(ms)
    __fpga_f_sleep_ms(ms)
  end

  # mrb_define_module_function_id の特異メソッドの側
  # C: mrbgems/mruby-task/src/task.c mrb_f_sleep_ms
  def self.sleep_ms(ms)
    __fpga_f_sleep_ms(ms)
  end
end

class Object
  # C: mrbgems/mruby-task/src/task.c mrb_f_sleep_ms
  def __fpga_f_sleep_ms(ms)
    ms = __fpga_as_int(ms) # mrb_get_args の "i"
    __fpga_raise(ArgumentError, "time interval must be positive") if ms < 0
    __fpga_sleep_ms_impl(__fpga_uint32(ms)) # (uint32_t)ms
    nil
  end

  # C: mrbgems/mruby-task/src/task.c sleep_ms_impl
  def __fpga_sleep_ms_impl(ms)
    __fpga_sleep_us_impl(__fpga_uint32(ms * 1000))
  end

  # task の中なら WAITING にして scheduler で待つ。task の外 (起動と mrblib) と C の関数の中は HAL で止まって待つ
  # C: mrbgems/mruby-task/src/task.c sleep_us_impl (D103)
  def __fpga_sleep_us_impl(usec)
    t = __fpga_image(54) # L:IMG_task_running MRB2TASK (D103)
    if t == 0 || __fpga_task_in_cfunc # mrb->c == mrb->root_c、または C の関数の中 (D105)
      __fpga_hal_task_sleep_us(usec)
      __fpga_st32(53 * 4, 0) # L:IMG_task_switching L:WORD
      return nil
    end
    __fpga_task_q_delete(t)
    __fpga_st8(t + 5, 4) # L:TK_STATUS L:TASK_STATUS_WAITING
    __fpga_st8(t + 6, 1) # L:TK_REASON L:TASK_REASON_SLEEP
    wakeup = __fpga_task_normalize_wakeup(__fpga_uint32(__fpga_image(51) + usec / 1000 / 4)) # L:IMG_task_tick L:TASK_TICK_UNIT
    __fpga_st32(t + 8, wakeup) # L:TK_WAKEUP
    w = __fpga_image(52) # L:IMG_task_wakeup_tick
    __fpga_st32(52 * 4, wakeup) if w == 4294967295 || __fpga_int32(wakeup - w) < 0 # L:IMG_task_wakeup_tick L:WORD
    __fpga_task_q_insert(t)
    __fpga_st32(53 * 4, 1) # L:IMG_task_switching L:WORD
    __fpga_task_run_body # VM から scheduler へ戻る代わりに、ここで scheduler を回す (D103)
    nil
  end

  # C の関数の中か (sleep_us_impl の ci->cci > 0 の検査、D105)。プログラムの __fpga_run のフレームより上だけを見る。
  # sleep を呼んだ firmware のフレームの並び (C の関数そのもの) より下に、cci > 0 のフレームか firmware のフレームがあれば真
  # C: mrbgems/mruby-task/src/task.c sleep_us_impl (D105)
  def __fpga_task_in_cfunc
    heap = __fpga_image(35) # L:IMG_heap_start
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI
    base = __fpga_ld32(__fpga_image(0) + 16) # L:IMG_c L:CTX_CIBASE
    run = ci
    run -= 64 while run > base && (__fpga_ld8(run + 3) == 5) == false # L:CI_SIZE L:CI_CONT L:CONT_RUN
    ci -= 64 while ci > run && __fpga_ld32(ci + 8) < heap # L:CI_SIZE L:CI_PROC
    while ci > run
      return true if __fpga_ld8(ci + 1) > 0 || __fpga_ld32(ci + 8) < heap # L:CI_CCI L:CI_PROC
      ci -= 64 # L:CI_SIZE
    end
    false
  end

  # C: mrbgems/mruby-task/include/task.h mrb_task_normalize_wakeup
  def __fpga_task_normalize_wakeup(deadline)
    deadline == 4294967295 ? 4294967294 : deadline
  end

  # task の状態が入る queue の見出しの番地 (mrb_state.task.queues の語)
  # C: mrbgems/mruby-task/src/task.c q_get_queue
  def __fpga_task_q_get_queue(t)
    s = __fpga_ld8(t + 5) # L:TK_STATUS
    return 48 * 4 if s == 2 || s == 3 # L:IMG_task_q_ready L:WORD L:TASK_STATUS_READY L:TASK_STATUS_RUNNING
    return 49 * 4 if s == 4 # L:IMG_task_q_waiting L:WORD L:TASK_STATUS_WAITING
    return 50 * 4 if s == 8 # L:IMG_task_q_suspended L:WORD L:TASK_STATUS_SUSPENDED
    47 * 4 # L:IMG_task_q_dormant L:WORD
  end

  # priority の順 (小さい方が先)、同じ priority は後ろへ
  # C: mrbgems/mruby-task/src/task.c mrb_task_q_insert
  def __fpga_task_q_insert(t)
    q = __fpga_task_q_get_queue(t)
    curr = __fpga_ld32(q)
    prev = 0
    priority = __fpga_ld8(t + 4) # L:TK_PRIORITY
    while curr > 0 && __fpga_ld8(curr + 4) <= priority # L:TK_PRIORITY
      prev = curr
      curr = __fpga_ld32(curr + 0) # L:TK_NEXT
    end
    __fpga_st32(t + 0, curr) # L:TK_NEXT
    if prev == 0
      __fpga_st32(q, t)
    else
      __fpga_st32(prev + 0, t) # L:TK_NEXT
    end
  end

  # C: mrbgems/mruby-task/src/task.c mrb_task_q_delete
  def __fpga_task_q_delete(t)
    q = __fpga_task_q_get_queue(t)
    curr = __fpga_ld32(q)
    prev = 0
    while curr > 0
      if curr == t
        if prev == 0
          __fpga_st32(q, __fpga_ld32(curr + 0)) # L:TK_NEXT
        else
          __fpga_st32(prev + 0, __fpga_ld32(curr + 0)) # L:TK_NEXT L:TK_NEXT
        end
        __fpga_st32(t + 0, 0) # L:TK_NEXT
        return nil
      end
      prev = curr
      curr = __fpga_ld32(curr + 0) # L:TK_NEXT
    end
    nil
  end

  # 起動がプログラムを 1 本走らせる前に作る main task (picoruby-bin-picoruby の mrc_create_task → mrb_create_task。
  # 構造体の所だけで、context と Task の物は作らない、D103)
  # C: mrbgems/mruby-task/src/task.c task_create_common (D103)
  def __fpga_task_create
    t = __fpga_alloc(16) # L:TK_SIZE
    __fpga_st32(t + 0, 0) # L:TK_NEXT
    __fpga_st8(t + 4, 128) # L:TK_PRIORITY L:TASK_PRIORITY_DEFAULT
    __fpga_st8(t + 5, 2) # L:TK_STATUS L:TASK_STATUS_READY
    __fpga_st8(t + 6, 0) # L:TK_REASON L:TASK_REASON_NONE
    __fpga_st8(t + 7, 0) # L:TK_TIMESLICE
    __fpga_st32(t + 8, 0) # L:TK_WAKEUP
    __fpga_task_q_insert(t)
    t
  end

  # task を走らせる所 (context の切り替えの代わりに、走っている task を置く、D103)
  # C: mrbgems/mruby-task/src/task.c execute_task (D103)
  def __fpga_execute_task(t)
    __fpga_st8(t + 7, 3) # L:TK_TIMESLICE L:TASK_TIMESLICE
    __fpga_st8(t + 5, 3) # L:TK_STATUS L:TASK_STATUS_RUNNING
    __fpga_st32(54 * 4, t) # L:IMG_task_running L:WORD
    __fpga_st32(53 * 4, 0) # L:IMG_task_switching L:WORD
  end

  # task の終わり (execute_task の Handle task termination。プログラムの __fpga_run が戻った所)
  # C: mrbgems/mruby-task/src/task.c execute_task (D103)
  def __fpga_task_stopped(t)
    __fpga_st32(53 * 4, 0) # L:IMG_task_switching L:WORD
    __fpga_task_q_delete(t)
    __fpga_st8(t + 5, 0) # L:TK_STATUS L:TASK_STATUS_DORMANT
    __fpga_task_q_insert(t)
    __fpga_st32(54 * 4, 0) # L:IMG_task_running L:WORD
  end

  # scheduler の loop。ready の task が無ければ idle で待つ。task は main の 1 つなので、ready になったらそれを走らせる
  # (sleep から戻る) (D103)。GC の step は S6
  # C: mrbgems/mruby-task/src/task.c task_run_body (D103)
  def __fpga_task_run_body
    while true
      t = __fpga_image(48) # L:IMG_task_q_ready
      if t > 0
        __fpga_execute_task(t)
        return nil
      end
      __fpga_halt if __fpga_image(49) == 0 && __fpga_image(50) == 0 # L:IMG_task_q_waiting L:IMG_task_q_suspended 全 task が dormant
      __fpga_hal_task_idle_cpu
    end
  end

  # tick の割り込み (MRB_TICK_UNIT ms ごと)
  # C: mrbgems/mruby-task/src/task.c mrb_tick
  def __fpga_tick
    tick = __fpga_uint32(__fpga_image(51) + 1) # L:IMG_task_tick
    __fpga_st32(51 * 4, tick) # L:IMG_task_tick L:WORD
    t = __fpga_image(48) # L:IMG_task_q_ready
    if t > 0 && __fpga_ld8(t + 5) == 3 && __fpga_ld8(t + 7) > 0 # L:TK_STATUS L:TASK_STATUS_RUNNING L:TK_TIMESLICE
      __fpga_st8(t + 7, __fpga_ld8(t + 7) - 1) # L:TK_TIMESLICE
      __fpga_st32(53 * 4, 1) if __fpga_ld8(t + 7) == 0 # L:IMG_task_switching L:WORD L:TK_TIMESLICE
    end
    w = __fpga_image(52) # L:IMG_task_wakeup_tick
    return nil if w == 4294967295 || __fpga_int32(w - tick) > 0
    curr = __fpga_image(49) # L:IMG_task_q_waiting
    next_wakeup = 4294967295
    while curr > 0
      nxt = __fpga_ld32(curr + 0) # L:TK_NEXT
      curr_wakeup = 4294967295
      curr_wakeup = __fpga_ld32(curr + 8) if __fpga_ld8(curr + 6) == 1 # L:TK_WAKEUP L:TK_REASON L:TASK_REASON_SLEEP
      if (curr_wakeup == 4294967295) == false
        if __fpga_int32(curr_wakeup - tick) > 0
          next_wakeup = curr_wakeup if next_wakeup == 4294967295 || __fpga_int32(curr_wakeup - next_wakeup) < 0
        else
          __fpga_task_q_delete(curr)
          __fpga_st8(curr + 5, 2) # L:TK_STATUS L:TASK_STATUS_READY
          __fpga_st8(curr + 6, 0) # L:TK_REASON L:TASK_REASON_NONE
          __fpga_task_q_insert(curr)
          __fpga_st32(53 * 4, 1) # L:IMG_task_switching L:WORD
        end
      end
      curr = nxt
    end
    __fpga_st32(52 * 4, next_wakeup) # L:IMG_task_wakeup_tick L:WORD
    nil
  end

  # --- HAL (FPGA の板のモデル、D102)
  # mrb_mruby_task_gem_init の状態の初期化と mrb_hal_task_init (tick の timer は板が回す)
  # C: mrbgems/mruby-task/ports/posix/task_hal.c mrb_hal_task_init (D102)
  def __fpga_init_task
    __fpga_st32(47 * 4, 0) # L:IMG_task_q_dormant L:WORD
    __fpga_st32(48 * 4, 0) # L:IMG_task_q_ready L:WORD
    __fpga_st32(49 * 4, 0) # L:IMG_task_q_waiting L:WORD
    __fpga_st32(50 * 4, 0) # L:IMG_task_q_suspended L:WORD
    __fpga_st32(51 * 4, 0) # L:IMG_task_tick L:WORD
    __fpga_st32(52 * 4, 4294967295) # L:IMG_task_wakeup_tick L:WORD
    __fpga_st32(53 * 4, 0) # L:IMG_task_switching L:WORD
    __fpga_st32(54 * 4, 0) # L:IMG_task_running L:WORD
  end

  # 割り込みを待ち (WFI)、来た割り込みを処理する
  # C: mrbgems/mruby-task/ports/posix/task_hal.c mrb_hal_task_idle_cpu (D102)
  def __fpga_hal_task_idle_cpu
    __fpga_st32(67108900, 1) # L:MMIO_WFI
    __fpga_task_irq
  end

  # tick の割り込みの処理 (posix は SIGALRM の handler が mrb_tick を呼ぶ)
  # C: mrbgems/mruby-task/ports/posix/task_hal.c sigalrm_handler (D102)
  def __fpga_task_irq
    if __fpga_and(__fpga_ld32(67108904), 1) > 0 # L:MMIO_IRQ L:MMIO_IRQ_TICK
      __fpga_st32(67108904, 1) # L:MMIO_IRQ L:MMIO_IRQ_TICK
      __fpga_tick
    end
  end

  # 止まって待つ sleep: tick の単位に切り捨てた数だけ idle で待つ (D100)
  # C: mrbgems/mruby-task/ports/posix/task_hal.c mrb_hal_task_sleep_us (D100)
  def __fpga_hal_task_sleep_us(usec)
    n = usec / (4 * 1000) # L:TASK_TICK_UNIT
    while n > 0
      __fpga_hal_task_idle_cpu
      n -= 1
    end
  end

  # --- C の整数の型 (D104)
  # (uint32_t)x
  # C: none (D104)
  def __fpga_uint32(x)
    __fpga_and(x, 4294967295)
  end

  # (int32_t)x、(int)x
  # C: none (D104)
  def __fpga_int32(x)
    u = __fpga_and(x, 4294967295)
    u >= 2147483648 ? u - 4294967296 : u
  end
end
