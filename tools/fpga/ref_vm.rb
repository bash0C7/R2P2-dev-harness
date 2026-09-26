# CPU コアの参照インタプリタ (ゴールデンモデル)。
#
# ROM (rom.rb の 48bit 語) を1命令ずつ実行し、ハードウェアのシミュレーション
# (fpga/sim/mrb_run_tb.sv) と同じ書式のトレースを出す。命令の意味の正本は
# mruby/mruby の src/vm.c。ここに書くのは FPGA 版として決めた意味 (docs/spec.md §10):
#   - 整数は 32bit で折り返す (mruby の Integer の範囲外は仕様外)
#   - 型の合わない演算、0 での割り算、範囲外は「エラー停止」(mruby ならメソッド探索や例外)
#   - メソッド呼び出しはレジスタ窓: 呼び出し先の R0 は呼び出し元の R[a]。レジスタファイルは全フレームで共有
#   - RETURN / RETNIL はフレームが無ければ停止、あれば呼び出し元へ戻る。STOP は停止
#   - 配列と Proc はヒープのオブジェクト。ヒープが足りなくなったらコピー GC。GC の順番もハードウェアと同じ
#     (移ったオブジェクトのアドレスまで一致させる)
#   - Proc は作ったフレームの env と外側の Proc を持つ。env はフレームが生きている間はその bp を指し、
#     フレームから戻る時にレジスタを写し取る (mruby の REnv と同じ)。外側の変数 (GETUPVAR / SETUPVAR / BLKPUSH) は
#     「深さ k のフレームの env」を Proc の連鎖でたどって読む
#   - lambda は引数の数を調べ、その中の return / break は lambda から戻る
#
# トレース (1行1イベント、数値は10進、値は16進8桁):
#   X <step> <pc> <op>          命令を実行した
#   W <step> <reg> <tag> <val>  レジスタに書いた (reg はレジスタファイルでの番号 = フレームの底 + R の番号)
#   O <step> <port> <tag> <val> I/O ポートに書いた (SETGV)
#   H <step> <pc>               停止命令で止まった
#   E <step> <pc> <op>          エラーで止まった
#   L <step>                    命令数の上限に達した
# 合否は O 行と最後の1行 (H/E/L) で見る。X/W 行はずれた場所を探すため。
# 呼び出しでの self の写しと呼び出し先のレジスタの nil 埋め、SETCONST、ヒープへの書き込み、GC は
# トレースに出さない (ハードウェアも出さない)。
require_relative "converter"
require_relative "compare"

class FpgaRefVm
  MASK = (1 << FpgaIsa::INT_BITS) - 1
  NIL = [FpgaIsa::TAG_NIL, 0].freeze
  HALF = FpgaIsa::HEAP_SIZE / 2

  class Fault < StandardError; end # 命令の途中のエラー (エラー停止にする)

  # stim: [[step, port, value], ...]。step 以降の命令から port の入力が value になる。
  def initialize(words, nregs: FpgaIsa::RF_SIZE, stim: [])
    @rom = words
    @regs = Array.new(nregs) { NIL }
    @io = Array.new(FpgaIoMap::NPORTS) { NIL }
    @consts = Array.new(FpgaIsa::NCONST)
    @heap = Array.new(FpgaIsa::HEAP_SIZE) { NIL }
    @space = 0
    @hp = 0
    @stack = [] # [戻り先の pc, 呼び出し元の bp, 呼び出し元の Proc, 呼び出し元の env, 呼び出し元の nregs]
    @bp = 0
    @cp = NIL   # 今のフレームが Proc (ブロック) ならその参照
    @env = NIL  # 今のフレームの env (中で Proc を作った時にできる)
    @fn = 0     # 今のフレームの nregs (env に写す数。一番外は戻らないので 0)
    @argc = 0
    # step の順、同じ step なら与えられた順 (後が勝つ)。テストベンチもこの順で適用する
    @stim = FpgaCompare.sort_stim(stim)
    @trace = []
    @stats = Hash.new(0)
  end

  attr_reader :trace, :regs, :io, :consts, :heap, :stats

  # 珍しい経路を通った回数 (ファズがそこまで届いているかを見るため)。:gc, :detach, :env_heap, :lambda_exit, :aref
  def gcs
    @stats[:gc]
  end

  def run(max_steps)
    pc = 0
    step = 0
    loop do
      if step >= max_steps
        @trace << "L #{step}"
        break
      end
      # ROM の空きは全 bit 1 (op 0xff、未対応命令) で埋まっている。ハードウェアと同じくエラーになる
      op, a, b, c = FpgaRom.unpack(@rom[pc] || FpgaRom::PAD)
      @trace << format("X %d %d %02x", step, pc, op)
      result = begin
        execute(step, pc, op, a, b, c)
      rescue Fault
        :error
      end
      case result
      when :halt
        @trace << "H #{step} #{pc}"
        break
      when :error
        @trace << format("E %d %d %02x", step, pc, op)
        break
      else
        pc = result
      end
      step += 1
    end
    @trace
  end

  private

  def int(v)
    [FpgaIsa::TAG_INT, v & MASK]
  end

  def signed(v)
    v &= MASK
    v >= (1 << (FpgaIsa::INT_BITS - 1)) ? v - (1 << FpgaIsa::INT_BITS) : v
  end

  def sext16(v)
    v >= 0x8000 ? v - 0x10000 : v
  end

  def int?(r)
    r[0] == FpgaIsa::TAG_INT
  end

  def ary?(r)
    r[0] == FpgaIsa::TAG_ARRAY
  end

  def proc?(r)
    r[0] == FpgaIsa::TAG_PROC
  end

  def ref?(r)
    ary?(r) || proc?(r)
  end

  def truthy?(r)
    r[0] != FpgaIsa::TAG_NIL && r[0] != FpgaIsa::TAG_FALSE
  end

  def bool(x)
    [x ? FpgaIsa::TAG_TRUE : FpgaIsa::TAG_FALSE, 0]
  end

  def fault!
    raise Fault
  end

  def ok?(r)
    @bp + r < @regs.size
  end

  def reg(r)
    fault! unless ok?(r)
    @regs[@bp + r]
  end

  def set(step, r, value)
    fault! unless ok?(r)
    set_abs(step, @bp + r, value)
  end

  def set_abs(step, i, value)
    fault! unless i < @regs.size
    @regs[i] = value
    @trace << format("W %d %d %d %08x", step, i, value[0], value[1])
    nil
  end

  def input(step, port)
    v = 0
    @stim.each { |s, p, val| v = val if p == port && s <= step }
    int(v)
  end

  # ---- ヒープ

  def hdr(kind, size)
    [FpgaIsa::TAG_HDR, (kind << 16) | size]
  end

  # n 語を確保して先頭の語アドレスを返す。足りなければ GC し、それでも足りなければエラー
  def alloc(n)
    gc if @hp + n > (@space + 1) * HALF
    fault! if @hp + n > (@space + 1) * HALF
    p = @hp
    @hp += n
    p
  end

  # Cheney のコピー GC。ルートはレジスタファイル全部 (番号順)、定義済みの定数 (番号順)、
  # コールスタックの Proc と env (底から、1段ごとに Proc、env の順)、今の Proc、今の env。ハードウェアも同じ順に写す
  def gc
    @stats[:gc] += 1
    @space = 1 - @space
    @free = @space * HALF
    @regs.each_index { |i| @regs[i] = forward(@regs[i]) }
    @consts.each_index { |i| @consts[i] = forward(@consts[i]) if @consts[i] }
    @stack.each do |fr|
      fr[2] = forward(fr[2])
      fr[3] = forward(fr[3])
    end
    @cp = forward(@cp)
    @env = forward(@env)
    scan = @space * HALF
    while scan < @free
      w = @heap[scan]
      @heap[scan] = forward(w) unless w[0] == FpgaIsa::TAG_HDR
      scan += 1
    end
    @hp = @free
  end

  def forward(v)
    return v unless ref?(v)
    p = v[1]
    h = @heap[p]
    return [v[0], h[1]] if h[0] == FpgaIsa::TAG_FWD
    size = h[1] & 0xFFFF
    (0..size).each { |i| @heap[@free + i] = @heap[p + i] }
    @heap[p] = [FpgaIsa::TAG_FWD, @free]
    moved = [v[0], @free]
    @free += size + 1
    moved
  end

  # 配列: 見出し p、長さ p+1、中身の参照 p+2。中身 d: 見出し d、要素 d+1..
  def new_array(values)
    cap = values.size
    p = alloc(4 + cap)
    @heap[p] = hdr(FpgaIsa::KIND_ARY, 2)
    @heap[p + 1] = int(cap)
    @heap[p + 2] = [FpgaIsa::TAG_ARRAY, p + 3]
    @heap[p + 3] = hdr(FpgaIsa::KIND_DATA, cap)
    p
  end

  def ary_len(a)
    @heap[a[1] + 1][1]
  end

  def ary_data(a)
    @heap[a[1] + 2][1]
  end

  def ary_cap(a)
    @heap[ary_data(a)][1] & 0xFFFF
  end

  def ary_get(a, i)
    @heap[ary_data(a) + 1 + i]
  end

  # R[ra][i] = R[rv]。i は 0 以上。長さを超えたら間を nil で埋め、容量を超えたら中身を作り直す。
  # 作り直しで GC が走ると配列も値も動くので、どちらもレジスタから読み直す
  def ary_set(ra, i, rv)
    a = reg(ra)
    len = ary_len(a)
    if i >= ary_cap(a)
      newcap = [i + 1, ary_cap(a) * 2, 4].max
      d = alloc(1 + newcap)
      a = reg(ra)
      old = ary_data(a)
      @heap[d] = hdr(FpgaIsa::KIND_DATA, newcap)
      newcap.times { |k| @heap[d + 1 + k] = k < len ? @heap[old + 1 + k] : NIL }
      @heap[a[1] + 2] = [FpgaIsa::TAG_ARRAY, d]
    end
    d = ary_data(a)
    (len...i).each { |k| @heap[d + 1 + k] = NIL }
    @heap[d + 1 + i] = reg(rv)
    @heap[a[1] + 1] = int(i + 1) if i >= len
  end

  # Proc: 見出し p、{先頭 pc | 引数の数 << 16 | lambda << 23 | nregs << 24}、作ったフレームの env、外側の Proc。
  # 今のフレームに env が無ければ、Proc と一緒に1回で確保する (env が先、中身は nil)
  def new_proc(entry_word)
    fresh = @env[0] == FpgaIsa::TAG_NIL
    p = alloc((fresh ? 2 + @fn : 0) + 4)
    if fresh
      @heap[p] = hdr(FpgaIsa::KIND_ENV, 1 + @fn)
      @heap[p + 1] = int(@bp)
      @fn.times { |i| @heap[p + 2 + i] = NIL }
      @env = [FpgaIsa::TAG_ENV, p]
      p += 2 + @fn
    end
    @heap[p] = hdr(FpgaIsa::KIND_PROC, 3)
    @heap[p + 1] = int(entry_word)
    @heap[p + 2] = @env
    @heap[p + 3] = @cp
    p
  end

  def lambda?(pr)
    proc?(pr) && ((@heap[pr[1] + 1][1] >> 23) & 1) == 1
  end

  # 深さ k の Proc。0 は今の Proc、1 はそれを作ったフレームの Proc ...
  def proc_at(k)
    fault! if k > 15
    p = @cp
    k.times do
      fault! unless proc?(p)
      p = @heap[p[1] + 3]
    end
    p
  end

  # 深さ k (1 以上) のフレームの env
  def env_at(k)
    p = proc_at(k - 1)
    fault! unless proc?(p)
    @heap[p[1] + 2]
  end

  # 深さ k のフレームの i 番目のレジスタの場所: [:reg, 番号] (生きている) か [:heap, 語アドレス] (退避済み)
  def slot(k, i)
    return [:reg, @bp + i] if k.zero?
    e = env_at(k)[1]
    live = @heap[e + 1]
    return [:reg, live[1] + i] if live[0] == FpgaIsa::TAG_INT
    @stats[:env_heap] += 1
    fault! if i >= (@heap[e][1] & 0xFFFF) - 1
    [:heap, e + 2 + i]
  end

  def read_slot(k, i)
    kind, n = slot(k, i)
    kind == :reg ? (@regs[n] || fault!) : @heap[n]
  end

  # 深さ k のフレームの底 (生きていなければエラー: 戻ったメソッドへの break / return)
  def frame_base(k)
    return @bp if k.zero?
    live = @heap[env_at(k)[1] + 1]
    fault! unless live[0] == FpgaIsa::TAG_INT
    live[1]
  end

  # フレームから出る前に、その env にレジスタを写し取る
  def detach
    return if @env[0] == FpgaIsa::TAG_NIL
    @stats[:detach] += 1
    e = @env[1]
    n = (@heap[e][1] & 0xFFFF) - 1
    n.times { |i| @heap[e + 2 + i] = @regs[@bp + i] }
    @heap[e + 1] = NIL
  end

  def pop_frame
    detach
    pc, @bp, @cp, @env, @fn = @stack.pop
    pc
  end

  # ---- 実行

  def execute(step, pc, op, a, b, c)
    name = FpgaIsa::OPS[op]&.name
    return :error unless name && FpgaIsa.supported?(name)
    nxt = pc + 1
    return :error if !ok?(a) && !%w[NOP JMP RETNIL STOP].include?(name)

    case name
    when "NOP" then nil
    when "MOVE" then set(step, a, reg(b))
    when "LOADI8"   then set(step, a, int(b & 0xFF))
    when "LOADINEG" then set(step, a, int(-(b & 0xFF)))
    when "LOADI__1" then set(step, a, int(-1))
    when /\ALOADI_(\d)\z/ then set(step, a, int(Regexp.last_match(1).to_i))
    when "LOADI16"  then set(step, a, int(sext16(b)))
    when "LOADI32"  then set(step, a, int((b << 16) | c))
    when "LOADNIL", "TDEF" then set(step, a, NIL)
    when "LOADTRUE" then set(step, a, bool(true))
    when "LOADFALSE" then set(step, a, bool(false))
    when "GETGV"
      port = b & 0xFF
      fault! if port >= FpgaIoMap::NPORTS
      set(step, a, FpgaIoMap::IN_MASK[port] == 1 ? input(step, port) : @io[port])
    when "SETGV"
      port = b & 0xFF
      v = reg(a)
      fault! if port >= FpgaIoMap::NPORTS || ref?(v) # 配列や Proc はピンに出せない
      @io[port] = v
      @trace << format("O %d %d %d %08x", step, port, v[0], v[1])
    when "GETCONST"
      fault! if b >= FpgaIsa::NCONST || @consts[b].nil?
      set(step, a, @consts[b])
    when "SETCONST"
      fault! if b >= FpgaIsa::NCONST
      @consts[b] = reg(a)
    when "JMP" then return b
    when "JMPIF"  then return(truthy?(reg(a)) ? b : nxt)
    when "JMPNOT" then return(truthy?(reg(a)) ? nxt : b)
    when "JMPNIL" then return(reg(a)[0] == FpgaIsa::TAG_NIL ? b : nxt)
    when "ADD", "SUB", "MUL", "DIV", "EQ", "LT", "LE", "GT", "GE" then binop(step, name, a)
    when "ADDI", "SUBI"
      fault! unless int?(reg(a))
      d = b & 0xFF
      set(step, a, int(name == "ADDI" ? reg(a)[1] + d : reg(a)[1] - d))
    when "ADDILV", "SUBILV"
      fault! unless int?(reg(a))
      d = c & 0xFF
      set(step, a, int(name == "ADDILV" ? reg(a)[1] + d : reg(a)[1] - d))
    when "SEND", "SEND0" then builtin(step, b, a, c)
    when "SSEND", "SSEND0" then return call(pc, a, b, c)
    when "ENTER" then return(@argc == a ? nxt : :error)
    when "RETURN", "RETNIL" then return ret(step, name == "RETURN" ? reg(a) : NIL)
    when "STOP" then return :halt
    when "BREAK" then return brk(step, a, b, c)
    when "RETURN_BLK" then return return_blk(step, a, c)
    when "GETUPVAR", "BLKPUSH" then set(step, a, read_slot(c, b))
    when "SETUPVAR"
      kind, n = slot(c, b)
      if kind == :reg
        set_abs(step, n, reg(a))
      else
        @heap[n] = reg(a) # 退避済みの env への書き込みはトレースに出さない (ヒープと同じ)
      end
    when "BLOCK"
      fault! unless ok?(a)
      set(step, a, [FpgaIsa::TAG_PROC, new_proc((b & 0xFFFF) | ((c & 0xFF) << 16) | ((c >> 8) << 24))])
    when "BLKCALL" then return blkcall(pc, a, b)
    when "ARRAY"
      fault! unless b.zero? || ok?(a + b - 1)
      p = new_array(Array.new(b))
      b.times { |i| @heap[p + 4 + i] = reg(a + i) }
      set(step, a, [FpgaIsa::TAG_ARRAY, p])
    when "ARRAY2"
      fault! unless c.zero? || ok?(b + c - 1)
      p = new_array(Array.new(c))
      c.times { |i| @heap[p + 4 + i] = reg(b + i) }
      set(step, a, [FpgaIsa::TAG_ARRAY, p])
    when "GETIDX" then set(step, a, index(reg(a), reg(a + 1)))
    when "GETIDX0" then set(step, a, index(reg(b), int(0)))
    when "AREF" # 多重代入: 配列なら R[b][c]、配列でなければ c = 0 の時だけ R[b] 自身、ほかは nil
      v = reg(b)
      @stats[:aref] += 1
      set(step, a, ary?(v) ? index(v, int(c & 0xFF)) : (c.zero? ? v : NIL))
    when "SETIDX"
      arr = reg(a)
      idx = reg(a + 1)
      reg(a + 2)
      fault! unless ary?(arr) && int?(idx)
      i = signed(idx[1])
      i += ary_len(arr) if i < 0
      fault! if i < 0 || i >= 0x10000
      ary_set(a, i, a + 2)
    end
    nxt
  end

  def index(arr, idx)
    fault! unless ary?(arr) && int?(idx)
    i = signed(idx[1])
    len = ary_len(arr)
    i += len if i < 0
    i >= 0 && i < len ? ary_get(arr, i) : NIL
  end

  # 呼び出し: 呼び出し先のフレームの底は bp + a。R0 に self を写し、引数より後ろを nil で埋める。
  # c = (nregs << 8) | ブロックを渡す印 (0x80) | 引数の数。ブロックを渡す時はその枠 (引数の次) を残す
  def call(pc, a, target, c)
    argc = c & 0x7F
    keep = argc + ((c & 0x80).zero? ? 0 : 1)
    enter_frame(pc, a, c >> 8, keep, NIL)
    @argc = argc
    target
  end

  def enter_frame(pc, a, nregs, keep, new_cp)
    new_bp = @bp + a
    fault! if new_bp + [nregs, keep + 1].max > @regs.size || @stack.size >= FpgaIsa::STACK_DEPTH
    @stack.push([pc + 1, @bp, @cp, @env, @fn])
    @regs[new_bp] = @regs[@bp]
    ((keep + 1)...nregs).each { |i| @regs[new_bp + i] = NIL }
    @bp = new_bp
    @cp = new_cp
    @env = NIL
    @fn = nregs
  end

  # Proc を呼ぶ (yield / blk.call / iterator)。R[a] の Proc を、R[a+1].. の n 個の値で。
  # Proc の引数の数より少なければ残りは nil、多ければ捨てる。lambda は数が違えばエラー
  def blkcall(pc, a, n)
    pr = reg(a)
    fault! unless proc?(pr)
    ok?(a + n) || fault!
    info = @heap[pr[1] + 1][1]
    m1 = (info >> 16) & 0x7F
    nregs = (info >> 24) & 0xFF
    fault! if lambda?(pr) && n != m1
    enter_frame(pc, a, nregs, [n, m1].min, pr)
    info & 0xFFFF
  end

  # 戻り: 呼び出し先の R0 (= 呼び出し元の R[a]) に値を置いて戻る。フレームが無ければ停止
  def ret(step, value)
    return :halt if @stack.empty?
    callee = @bp
    pc = pop_frame
    set_abs(step, callee, value)
    pc
  end

  # break。c = 0: iterator に直接渡したブロック。フレームを1つ畳んで b (iterator の出口) へ。
  # c = 1: メソッドや Proc に渡したブロック。Proc を作ったフレームへ戻るまで畳み、その呼び出しの結果にする
  def brk(step, a, b, c)
    value = reg(a)
    fault! if @stack.empty?
    if c.zero?
      ret(step, value)
      return b
    end
    if lambda?(@cp) # lambda の中の break は lambda から戻る
      @stats[:lambda_exit] += 1
      return ret(step, value)
    end
    target = frame_base(1)
    loop do
      fault! if @stack.empty?
      callee = @bp
      pc = pop_frame
      if @bp == target
        set_abs(step, callee, value)
        return pc
      end
    end
  end

  # ブロックの中の return: ブロックを囲むメソッド (深さ c のフレーム) まで畳み、そのメソッドから戻る。
  # 途中に lambda があれば、一番内側の lambda から戻る (深さ d の Proc が lambda なら、深さ d のフレーム)
  def return_blk(step, a, c)
    value = reg(a)
    d = c
    p = @cp
    c.times do |k|
      fault! unless proc?(p)
      if lambda?(p)
        d = k
        break
      end
      p = @heap[p[1] + 3]
    end
    @stats[:lambda_exit] += 1 if d < c
    target = frame_base(d)
    until @bp == target
      fault! if @stack.empty?
      pop_frame
    end
    fault! if @stack.empty?
    ret(step, value)
  end

  def shift_left(x, s)
    return int(0) if s >= FpgaIsa::INT_BITS
    return int(x < 0 ? -1 : 0) if s <= -FpgaIsa::INT_BITS
    s >= 0 ? int(x << s) : int(x >> -s)
  end

  def builtin(step, id, a, argc)
    name, want = FpgaIsa::BUILTINS[id]
    fault! unless name && want == argc
    x = reg(a)
    y = argc == 1 ? reg(a + 1) : nil
    if ary?(x)
      value = case name
              when "size", "length" then int(ary_len(x))
              when "empty?" then bool(ary_len(x).zero?)
              when "first" then ary_len(x).zero? ? NIL : ary_get(x, 0)
              when "last" then ary_len(x).zero? ? NIL : ary_get(x, ary_len(x) - 1)
              when "pop"
                len = ary_len(x)
                if len.zero?
                  NIL
                else
                  @heap[x[1] + 1] = int(len - 1)
                  ary_get(x, len - 1)
                end
              when "push", "<<"
                fault! if ary_len(x) >= 0xFFFF
                ary_set(a, ary_len(x), a + 1)
                reg(a)
              when "include?"
                fault! if ary?(y)
                bool((0...ary_len(x)).any? { |i| equal?(ary_get(x, i), y) })
              when "!" then bool(false)
              when "!=" then bool(!equal?(x, y))
              else fault!
              end
      return set(step, a, value)
    end
    value = case name
            when "!" then bool(!truthy?(x))
            when "!=" then bool(!equal?(x, y))
            when "sleep_ms", "sleep"
              # 時間はハードウェア (ボードエミュレーター) だけが持つ。値は待った量 (CRuby の sleep と同じく n)
              fault! unless int?(y) && signed(y[1]) >= 0
              y
            else
              fault! unless int?(x) && (y.nil? || int?(y))
              sx = signed(x[1])
              sy = y && signed(y[1])
              case name
              when "%"
                fault! if sy.zero?
                int(sx % sy) # Ruby の % は floor 側に丸めた余り
              when "-@" then int(-sx)
              when "<<" then shift_left(sx, sy)
              when ">>" then shift_left(sx, -sy)
              when "&" then int(sx & sy)
              when "|" then int(sx | sy)
              when "^" then int(sx ^ sy)
              when "~" then int(~sx)
              when "abs" then int(sx.abs)
              when "zero?" then bool(sx.zero?)
              when "even?" then bool(sx.even?)
              when "odd?" then bool(sx.odd?)
              else fault!
              end
            end
    set(step, a, value)
  end

  # == : Integer 同士は値、配列同士はエラー (中身の比較はしない)、それ以外は型と値 (参照は同じものか)
  def equal?(x, y)
    fault! if ary?(x) && ary?(y)
    x[0] == y[0] && (x[0] == FpgaIsa::TAG_INT || ref?(x) ? x[1] == y[1] : true)
  end

  def binop(step, name, a)
    x = reg(a)
    y = reg(a + 1)
    return set(step, a, bool(equal?(x, y))) if name == "EQ"
    fault! unless int?(x) && int?(y)
    sx = signed(x[1])
    sy = signed(y[1])
    value = case name
            when "ADD" then int(sx + sy)
            when "SUB" then int(sx - sy)
            when "MUL" then int(sx * sy)
            when "DIV"
              fault! if sy.zero?
              int(sx.div(sy)) # Ruby の / は floor 側に丸める。INT_MIN / -1 は折り返して INT_MIN
            when "LT"  then bool(sx < sy)
            when "LE"  then bool(sx <= sy)
            when "GT"  then bool(sx > sy)
            when "GE"  then bool(sx >= sy)
            end
    set(step, a, value)
  end
end
