# FPGA 版の Task (PicoRuby の mruby-task、src/task.c と src/task_queue.c と mrblib/queue.rb と同じ意味)。docs/spec.md §10「Task (P6)」。
# スケジューラーはここの Ruby で、コアは区画 (タスクごとのレジスタとコールスタック) の切り替えと tick の割り込みだけを持つ:
#   __task_init(区画, Proc) / __task_switch(区画) / __task_slot / __task_lock(真偽) / __task_on(ms か nil) / __hw_sleep_us(µs) / __halt
# 割り込み: 仮想の時計が __task_on で決めた ms (次に起きるタスクか timeslice の終わり) に届いた命令の区切りで
# Integer#__task_tick (受け手は今の ms)。tick は割り込みのたびにまとめて進める (1ms ごとに割り込まない)。一番外の STOP は
# Integer#__task_main_end (残りのタスクを走らせ終えてから止まる)。スケジューラーの中は __task_lock(true) で割り込みを止める。
# tick は R2P2 (Pico 2) と同じく 1ms、timeslice は 10 tick (build_config/r2p2-picoruby-pico2_w)。
#
# task.c との対応:
#   switching_ (S[SWITCHING]) を立てた API は、戻る時 (VM の命令の区切り) に今のタスクを降ろす (Task.__leave -> __schedule)
#   mrb_tick (Task.__catch_up): tick を進め、ready の列の先頭が走っていればその timeslice を減らし、0 で switching_。
#     起きる tick が来た待ちのタスクを ready へ (switching_)。列の先頭でないタスクの timeslice は減らない (task.c と同じ)
#   task_run_body の1周 (Task.__schedule): 降りたタスクを同じ優先度の後ろへ入れ直し、ready の先頭を timeslice 10 で走らせる
class Task
  class Error < StandardError; end

  TICK_UNIT = 1  # ms (MRB_TICK_UNIT)
  TIMESLICE = 10 # tick (MRB_TIMESLICE_TICK_COUNT)
  SLOTS = 8      # 区画の数 (tools/fpga/isa.rb の TASKS)
  # スケジューラーの状態 (Hash より浅く引けるように配列)。列は優先度の順 (数が小さいものが前、同じ優先度は後ろへ)
  S = [[], [], [], [], nil, 0, [], nil, false, 0x7FFFFFFF]
  READY_Q = 0
  WAITING_Q = 1
  SUSPENDED_Q = 2
  DORMANT_Q = 3
  CURRENT = 4   # 区画が走っているタスク (task.c の MRB2TASK)
  TICK = 5      # tick_
  SLOT_OF = 6   # 区画 -> タスク
  MAIN = 7
  SWITCHING = 8 # switching_
  WAKEUP = 9    # wakeup_tick_ (待っているタスクの一番早い起きる tick の目安。Task.stat に出る)
  NEVER = 0x7FFFFFFF # UINT32_MAX の代わり (Task.stat では -1)

  # main (区画 0)。PicoRuby では一番外のプログラムも優先度 128 のタスク
  def self.__boot
    return if S[MAIN]
    m = Task.new(__main: true)
    S[MAIN] = m
    S[CURRENT] = m
    S[SLOT_OF][0] = m
    Task.__insert(S[READY_Q], m)
  end

  # task.c の mrb_task_q_insert: 優先度の数が大きいものの前 (同じ優先度の後ろ)
  def self.__insert(q, t)
    i = 0
    i += 1 while i < q.size && q[i].priority <= t.priority
    q.insert(i, t)
  end

  def self.__queue(t)
    case t.status
    when :READY, :RUNNING then S[READY_Q]
    when :WAITING then S[WAITING_Q]
    when :SUSPENDED then S[SUSPENDED_Q]
    else S[DORMANT_Q]
    end
  end

  # 列から抜く (Array#delete より少ない命令で。スケジューラーは何度も呼ぶ)
  def self.__remove(q, t)
    i = 0
    while i < q.size
      if q[i].equal?(t)
        q.delete_at(i)
        return
      end
      i += 1
    end
  end

  # 待っているタスクの起きる tick のうち、limit より早い一番早いもの (無ければ limit)
  def self.__min_wake(limit)
    q = S[WAITING_Q]
    i = 0
    while i < q.size
      w = q[i].wake
      limit = w if w && w < limit
      i += 1
    end
    limit
  end

  # task_change_state: 列から抜いて、状態を変えて入れ直す
  def self.__move(t, status)
    Task.__remove(Task.__queue(t), t)
    t.__status = status
    Task.__insert(Task.__queue(t), t)
  end

  def self.__now_ms
    __io_read(0x112)
  end

  # tick を今の ms まで進める (task.c の mrb_tick を tick の数だけ)。次に何か起きる tick (起きるタスク、timeslice の終わり) ごとに
  # まとめて進める。走っているタスクに switching_ が立ったらそこで止める (その tick でタスクを降ろす)
  def self.__catch_up
    now = Task.__now_ms / TICK_UNIT
    while S[TICK] < now
      cur = S[CURRENT]
      break if S[SWITCHING] && cur.status == :RUNNING
      run = S[READY_Q][0].equal?(cur) && cur.status == :RUNNING && cur.timeslice > 0
      t = Task.__min_wake(now)
      t = S[TICK] + cur.timeslice if run && S[TICK] + cur.timeslice < t
      t = S[TICK] + 1 if t <= S[TICK]
      n = t - S[TICK]
      S[TICK] = t
      if run
        r = cur.timeslice - n
        if r <= 0
          if S[READY_Q].size == 1
            # ほかに ready が無い: task.c は譲ってすぐ同じタスクを走らせ直す (timeslice が戻る)
            r = TIMESLICE - (-r) % TIMESLICE
          else
            r = 0
            S[SWITCHING] = true
          end
        end
        cur.timeslice = r
      end
      next if S[WAKEUP] == NEVER || S[WAKEUP] > t
      nxt = NEVER
      S[WAITING_Q].dup.each do |w|
        next unless w.wake
        if w.wake <= t
          w.wake = nil
          w.reason = nil
          w.join_target = nil
          Task.__move(w, :READY)
          S[SWITCHING] = true
        elsif w.wake < nxt
          nxt = w.wake
        end
      end
      S[WAKEUP] = nxt
    end
  end

  # 次に割り込む ms: 起きるタスクの一番早い tick と、走っているタスクが列の先頭でほかに ready があれば timeslice の終わり
  def self.__arm
    nxt = Task.__min_wake(NEVER)
    cur = S[CURRENT]
    if S[READY_Q].size > 1 && S[READY_Q][0].equal?(cur) && cur.status == :RUNNING && cur.timeslice > 0
      e = S[TICK] + cur.timeslice
      nxt = e if e < nxt
    end
    nxt = S[TICK] + 1 if nxt <= S[TICK]
    __task_on(nxt * TICK_UNIT)
  end

  # API の入口 (割り込みを止め、main を作り、tick を今まで進める)。前の割り込みの許可を返す
  def self.__enter
    prev = __task_lock(true)
    Task.__boot
    Task.__catch_up
    prev
  end

  # API の出口 (VM の命令の区切り): switching_ なら今のタスクを降ろし、割り込みの時刻を決めて許可を戻す
  def self.__leave(prev)
    Task.__schedule if S[SWITCHING]
    Task.__arm
    __task_lock(prev)
  end

  # 今のタスクを降ろして次のタスクへ (task.c の execute_task の後半と task_run_body の1周)。
  # 走れるタスクが無ければ次に起きる tick まで仮想の時計を進める。どのタスクも残っていなければ main へ戻る (終わる)
  def self.__schedule
    cur = S[CURRENT]
    S[SWITCHING] = false
    cur.__status = :READY if cur.status == :RUNNING
    Task.__move(cur, :READY) if cur.status == :READY # 同じ優先度の後ろへ (round robin)
    while true
      Task.__catch_up
      t = S[READY_Q][0]
      if t
        # task_cleanup_if_stopped: 止めたタスク (terminate した、終わってから suspend / resume された) は走らせない
        if t.__stopped?
          Task.__move(t, :DORMANT) unless t.status == :DORMANT
          next
        end
        break
      end
      if S[WAITING_Q].empty? && S[SUSPENDED_Q].empty?
        t = S[MAIN] # 全部終わった
        break
      end
      wake = Task.__min_wake(NEVER)
      wake = S[TICK] + 1 if wake <= S[TICK] || wake == NEVER # 起こすものが無い (join、Queue): 次の tick まで
      __hw_sleep_us((wake - S[TICK]) * TICK_UNIT * 1000)
    end
    unless t.status == :DORMANT
      t.timeslice = TIMESLICE
      t.__status = :RUNNING
    end
    S[CURRENT] = t
    S[SWITCHING] = false
    Task.__arm
    __task_switch(t.__slot)
    # ここへ戻るのは、このタスクがまた選ばれた時。main が途中で terminate されていて全部終わったなら止まる
    __halt if S[CURRENT].equal?(S[MAIN]) && S[MAIN].__stopped? && !S[MAIN].__ended?
    nil
  end

  # タスクの本体 (区画はここから始まる)。例外はタスクの結果にする
  def self.__run(task, block)
    __task_lock(false)
    result = begin
      block.call
    rescue => e
      e
    end
    __task_lock(true)
    Task.__catch_up
    task.__finish(result, false)
    Task.__schedule
  end

  def self.__sleep_us(us)
    return __hw_sleep_us(us) unless S[MAIN] # タスクを作っていなければ待つだけ (main しかいない)
    prev = Task.__enter
    cur = S[CURRENT]
    cur.wake = S[TICK] + us / 1000 / TICK_UNIT
    cur.reason = :sleep
    Task.__move(cur, :WAITING)
    S[WAKEUP] = cur.wake if S[WAKEUP] == NEVER || cur.wake < S[WAKEUP]
    S[SWITCHING] = true
    Task.__leave(prev)
    nil
  end

  # Task.new(name:, priority:) { }。main (区画 0) は __main: で Task.__boot が作る
  def initialize(name: nil, priority: 128, __main: false, &block)
    if __main
      __setup("main", 128, 0)
      @status = :RUNNING
      return
    end
    raise ArgumentError, "tried to create task without a block" if block.nil?
    raise TypeError, "name must be a String" unless name.nil? || name.is_a?(String)
    raise TypeError, "priority must be an Integer" unless priority.is_a?(Integer)
    raise ArgumentError, "priority must be 0-255" if priority < 0 || priority > 255
    prev = Task.__enter
    slot = 1
    slot += 1 while slot < SLOTS && S[SLOT_OF][slot] && !S[SLOT_OF][slot].__stopped?
    if slot >= SLOTS
      Task.__leave(prev)
      raise RuntimeError, "no room for a task (the FPGA core has #{SLOTS - 1} besides main)"
    end
    __setup(name, priority, slot)
    S[SLOT_OF][slot] = self
    t = self
    __task_init(slot, proc { Task.__run(t, block) })
    Task.__insert(S[READY_Q], self)
    # task.c と同じく、入れた後の列の先頭と比べる (先頭は今入れたタスクになるので、実際には切り替わらない)
    h = S[READY_Q][0]
    S[SWITCHING] = true if h.status == :RUNNING && @priority < h.priority
    Task.__leave(prev)
  end

  def __setup(name, priority, slot)
    @name = name
    @priority = priority
    @slot = slot
    @status = :READY
    @timeslice = TIMESLICE
    @result = nil
    @wake = nil
    @reason = nil
    @join_target = nil
    @stopped = false
    @ended = false
  end

  attr_accessor :timeslice, :wake, :reason, :join_target

  def __slot
    @slot
  end

  def __status=(s)
    @status = s
  end

  def __stopped?
    @stopped
  end

  def __ended?
    @ended
  end

  def __name
    @name
  end

  def status
    @status
  end

  def name
    @name.nil? ? "(noname)" : @name
  end

  def name=(n)
    @name = n
  end

  def priority
    @priority
  end

  def priority=(p)
    raise TypeError, "priority must be an Integer" unless p.is_a?(Integer)
    raise ArgumentError, "priority must be 0-255" if p < 0 || p > 255
    prev = Task.__enter
    @priority = p
    if @status == :READY || @status == :RUNNING
      Task.__remove(S[READY_Q], self)
      Task.__insert(S[READY_Q], self)
    end
    Task.__leave(prev)
    p
  end

  def value
    @result
  end

  # PicoRuby は #<Task:0x... 名前:状態> (番地)。ここは区画の番号
  def inspect
    "#<Task:#{@slot} #{@name.is_a?(String) ? @name : '(unnamed)'}:#{@status}>"
  end

  # 終わった (区画はここで止まったまま、次の Task.new が使う)。join で待っているタスクを起こす (wake_up_join_waiters)。
  # from_task: タスクの中から (terminate) なら、起こしたタスクの方が優先度が高ければ switching_
  def __finish(result, from_task)
    @result = result
    @stopped = true
    Task.__move(self, :DORMANT)
    S[WAITING_Q].dup.each do |w|
      next unless w.reason == :join && w.join_target.equal?(self)
      w.reason = nil
      w.join_target = nil
      Task.__move(w, :READY)
      S[SWITCHING] = true if from_task && !S[SWITCHING] && w.priority < S[CURRENT].priority
    end
  end

  def __end_main
    @ended = true
    __finish(nil, false) unless @status == :DORMANT
  end

  # task.c と同じく、待つ前の結果を返す (終わっていなければ nil)
  def join
    prev = Task.__enter
    cur = S[CURRENT]
    if cur.equal?(self)
      Task.__leave(prev)
      raise ArgumentError, "can't join self"
    end
    r = @result
    unless @status == :DORMANT
      cur.reason = :join
      cur.join_target = self
      Task.__move(cur, :WAITING)
      S[SWITCHING] = true
    end
    Task.__leave(prev)
    r
  end

  # 待っている・終わったタスクも止める (task.c と同じ)。走っているタスクか ready の列の先頭なら switching_
  def suspend
    prev = Task.__enter
    unless @status == :SUSPENDED
      need = S[READY_Q][0].equal?(self) || @status == :RUNNING
      Task.__move(self, :SUSPENDED)
      S[SWITCHING] = true if need
    end
    Task.__leave(prev)
    self
  end

  # 待っていた理由があれば waiting へ (起きる tick が過ぎていれば次の tick で起きる)
  def resume
    prev = Task.__enter
    if @status == :SUSPENDED
      target = @reason.nil? ? :READY : :WAITING
      Task.__move(self, target)
      h = S[READY_Q][0]
      S[SWITCHING] = true if target == :READY && h && h.status == :RUNNING && @priority < h.priority
      S[WAKEUP] = @wake if @wake && (S[WAKEUP] == NEVER || @wake < S[WAKEUP])
    end
    Task.__leave(prev)
    self
  end

  def terminate
    prev = Task.__enter
    unless @status == :DORMANT
      was_running = @status == :RUNNING
      __finish(@result, true)
      S[SWITCHING] = true if was_running
    end
    Task.__leave(prev)
    self
  end

  # 一番外の終わり (コアが割り込みで呼ぶ): main を終わりにして残りのタスクを走らせ、全部終わったら割り込みを止めて戻る (STOP で止まる)
  def self.__main_end
    Task.__catch_up
    S[MAIN].__end_main
    Task.__schedule
    __task_on(nil)
  end

  def self.current
    Task.__boot
    S[CURRENT]
  end

  def self.pass
    prev = Task.__enter
    S[SWITCHING] = true
    Task.__leave(prev)
    nil
  end

  def self.list
    prev = Task.__enter
    l = S[DORMANT_Q] + S[READY_Q] + S[WAITING_Q] + S[SUSPENDED_Q]
    Task.__leave(prev)
    l
  end

  def self.get(name)
    raise TypeError, "no implicit conversion into String" unless name.is_a?(String)
    Task.list.each { |t| return t if t.__name == name }
    nil
  end

  def self.tick
    prev = Task.__enter
    t = S[TICK] * TICK_UNIT
    Task.__leave(prev)
    t
  end

  def self.stat
    prev = Task.__enter
    sub = ->(q) { { count: q.size, tasks: q.dup } }
    # wakeup_tick: 待っているタスクが無ければ PicoRuby は UINT32_MAX (32bit の Integer では -1)
    st = { tick: S[TICK], wakeup_tick: S[WAKEUP] == NEVER ? -1 : S[WAKEUP], dormant: sub.call(S[DORMANT_Q]),
           ready: sub.call(S[READY_Q]), waiting: sub.call(S[WAITING_Q]), suspended: sub.call(S[SUSPENDED_Q]) }
    Task.__leave(prev)
    st
  end

  # スケジューラーはいつも回っている (task.c の mrb_task_run は2回目からは何もしない)
  def self.run
    nil
  end

  # Task::Queue (task_queue.c と mrblib/queue.rb)。空なら pop したタスクは push か close まで待つ
  class Queue
    WAIT_RETRY = Object.new
    WAIT_TIMEOUT = Object.new

    def initialize
      @items = []
      @closed = false
    end

    def push(obj)
      raise Task::Error, "queue closed" if @closed
      prev = Task.__enter
      @items << obj
      # 待っている1つを起こす (waiting の列の順)。起こせば switching_
      Task::S[Task::WAITING_Q].each do |w|
        next unless w.reason == :queue && w.join_target.equal?(self)
        w.reason = nil
        w.join_target = nil
        w.wake = nil
        Task.__move(w, :READY)
        Task::S[Task::SWITCHING] = true
        break
      end
      Task.__leave(prev)
      self
    end

    def <<(obj)
      push(obj)
    end

    def enq(obj)
      push(obj)
    end

    def pop(non_block = false, timeout_ms: nil)
      deadline = nil
      unless timeout_ms.nil?
        raise ArgumentError, "timeout cannot be combined with non_block" if non_block
        raise TypeError, "timeout_ms must be an Integer" unless timeout_ms.is_a?(Integer)
        raise ArgumentError, "timeout_ms must be non-negative" if timeout_ms < 0
        prev = Task.__enter
        deadline = Task::S[Task::TICK] + (timeout_ms + Task::TICK_UNIT - 1) / Task::TICK_UNIT
        Task.__leave(prev)
      end
      while true
        v = __pop_try(non_block, deadline)
        return nil if v.equal?(WAIT_TIMEOUT)
        return v unless v.equal?(WAIT_RETRY)
      end
    end

    def shift(non_block = false)
      pop(non_block)
    end

    def deq(non_block = false)
      pop(non_block)
    end

    # 取れれば値、閉じていて空なら nil。空なら待ちに入って WAIT_RETRY (起こされてから、もう一度)、期限を過ぎていれば WAIT_TIMEOUT
    def __pop_try(non_block, deadline)
      prev = Task.__enter
      unless @items.empty?
        v = @items.shift
        Task.__leave(prev)
        return v
      end
      if @closed
        Task.__leave(prev)
        return nil
      end
      if non_block
        Task.__leave(prev)
        raise Task::Error, "queue empty"
      end
      if deadline && deadline <= Task::S[Task::TICK]
        Task.__leave(prev)
        return WAIT_TIMEOUT
      end
      cur = Task::S[Task::CURRENT]
      cur.reason = :queue
      cur.join_target = self
      cur.wake = deadline
      Task.__move(cur, :WAITING)
      w = Task::S[Task::WAKEUP]
      Task::S[Task::WAKEUP] = deadline if deadline && (w == Task::NEVER || deadline < w)
      Task::S[Task::SWITCHING] = true
      Task.__leave(prev)
      WAIT_RETRY
    end

    def size
      @items.size
    end

    def length
      @items.size
    end

    def empty?
      @items.empty?
    end

    def clear
      @items.clear
      self
    end

    def close
      prev = Task.__enter
      unless @closed
        @closed = true
        Task::S[Task::WAITING_Q].dup.each do |w|
          next unless w.reason == :queue && w.join_target.equal?(self)
          w.reason = nil
          w.join_target = nil
          w.wake = nil
          Task.__move(w, :READY)
          Task::S[Task::SWITCHING] = true
        end
      end
      Task.__leave(prev)
      self
    end

    def closed?
      @closed
    end

    def num_waiting
      n = 0
      Task::S[Task::WAITING_Q].each { |w| n += 1 if w.reason == :queue && w.join_target.equal?(self) }
      n
    end
  end
end

class Integer
  # tick の割り込み (コアが呼ぶ。割り込みの間は tick が止まっている)。走っているタスクに switching_ が立てば降ろす
  def __task_tick
    Task.__catch_up
    Task.__schedule if Task::S[Task::SWITCHING]
    Task.__arm
    __task_lock(false)
  end

  # タスクがある時の一番外の終わり
  def __task_main_end
    Task.__main_end
  end
end

class Object
  def sleep_ms(ms)
    raise TypeError, "no implicit conversion into Integer" unless ms.is_a?(Integer)
    raise ArgumentError, "time interval must be positive" if ms < 0
    Task.__sleep_us(ms * 1000)
    nil
  end

  # 引数なしは今のタスクを suspend (resume まで)。秒 (Integer か Float) を待ち、待った秒 (切り捨て) を返す
  def sleep(sec = nil)
    if sec.nil?
      Task.current.suspend
      return nil
    end
    raise ArgumentError, "time interval must be positive" if sec < 0
    ms = (sec * 1000).to_i
    Task.__sleep_us(ms * 1000)
    ms / 1000
  end

  def usleep(us)
    raise ArgumentError, "time interval must be positive" if us < 0
    Task.__sleep_us(us)
    us
  end
end
