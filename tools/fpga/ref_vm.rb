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
require_relative "devices"
require_relative "fpconv"

class FpgaRefVm
  MASK = (1 << FpgaIsa::INT_BITS) - 1
  NIL = [FpgaIsa::TAG_NIL, 0].freeze
  HALF = FpgaIsa::HEAP_SIZE / 2

  class Fault < StandardError; end # 命令の途中のエラー (エラー停止にする)
  # Ruby の例外にできるエラー (isa.rb の CERR_*)。例外の表があれば Integer#__core_error を呼ぶ (core_error)
  class CoreError < StandardError
    attr_reader :kind, :a1, :a2, :base

    def initialize(kind, a1, a2, base = nil)
      super("core error #{kind}")
      @kind = kind
      @a1 = a1
      @a2 = a2
      @base = base
    end
  end

  # stim: [[step, port, value], ...]。step 以降の命令から port の入力が value になる。
  def initialize(words, nregs: FpgaIsa::RF_SIZE, stim: [])
    @rom = words
    @nregs = nregs
    # step の順、同じ step なら与えられた順 (後が勝つ)。テストベンチもこの順で適用する
    @stim = FpgaCompare.sort_stim(stim)
    @dev = FpgaDevices::Bank.new(@stim) # GPIO、時間、UART、RNG、PWM、ADC、IRQ、watchdog
    @trace = []
    @stats = Hash.new(0)
    boot(0)
  end

  # 電源を入れた時と watchdog の再起動 (コアのリセット): レジスタ・ヒープ・定数・ポート・仮想の時計を初めから。
  # step はデバイスの刺激のために数え続ける (仮想の時計はこの step から)
  def boot(step)
    @boot_step = step
    @regs = Array.new(@nregs) { NIL }
    @call_kw = 0 # 今の呼び出しのキーワード引数の印 (c の bit 8)
    @kw = 0      # 今のフレームの印 (ENTER が見る)
    @io = Array.new(FpgaIoMap::NPORTS) { NIL }
    @consts = Array.new(FpgaIsa::NCONST)
    @heap = Array.new(FpgaIsa::HEAP_SIZE) { NIL }
    @space = 0
    @hp = 0
    @stack = [] # [戻り先の pc, 呼び出し元の bp, 呼び出し元の Proc, 呼び出し元の env, 呼び出し元の nregs]
    @bp = 0
    @cp = NIL   # 今のフレームが Proc (ブロック) ならその参照
    @env = NIL  # 今のフレームの env (中で Proc を作った時にできる)
    @mcls = FpgaIsa::CLS_OBJECT # 今のメソッドが見つかったクラス (super の起点)
    @fn = 0     # 今のフレームの nregs (env に写す数。一番外は戻らないので 0)
    @argc = 0
    @exc = NIL  # 投げている例外か、巻き戻しの途中の塊 (EXCEPT が読む)
    @xval = NIL # 巻き戻しの途中で運ぶ値 (return / break の値。GC の根)
    @hbase = 0  # 例外の表 (HTABLE で決まる)
    @hcount = 0
    @tbase = 0  # メソッド表 (TABLE で決まる)
    @tsize = 0
    @slept = 0 # sleep した時間 (µs)。仮想の時計 = 始めた命令の数 + これ
  end

  # 仮想の時計 (µs): この step までに始めた命令の数 (started は今の命令を含めるか) + sleep した時間
  def vtime(step, started)
    step - @boot_step + (started ? 1 : 0) + @slept
  end

  attr_reader :trace, :regs, :io, :consts, :heap, :stats

  # 珍しい経路を通った回数 (ファズがそこまで届いているかを見るため)。:gc, :detach, :env_heap, :lambda_exit, :aref,
  # :found (メソッド表で見つかった呼び出し), :super (親クラスへたどった段)
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
      # 命令を始める前にデバイスが見る (IRQ の事象、watchdog)。期限を過ぎていれば再起動して pc 0 から
      if @dev.tick(step, vtime(step, false)) == :reboot
        @trace << "B #{step}"
        @stats[:reboot] += 1
        boot(step)
        pc = 0
        @dev.tick(step, vtime(step, false))
      end
      # ROM の空きは全 bit 1 (op 0xff、未対応命令) で埋まっている。ハードウェアと同じくエラーになる
      op, a, b, c = FpgaRom.unpack(@rom[pc] || FpgaRom::PAD)
      @trace << format("X %d %d %02x", step, pc, op)
      result = begin
        execute(step, pc, op, a, b, c)
      rescue Fault
        :error
      rescue CoreError => e
        core_error(pc, e)
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

  # ヒープのオブジェクトのクラス (見出しの上位 16bit)
  def obj_class(r)
    @heap[r[1]][1] >> 16
  end

  def ary?(r)
    ref?(r) && obj_class(r) == FpgaIsa::CLS_ARRAY
  end

  def str?(r)
    ref?(r) && obj_class(r) == FpgaIsa::CLS_STRING
  end

  # ROM の語 (ROM の大きさで折り返す。無い所は全 bit 1)
  def rom_word(addr)
    @rom[addr % (1 << FpgaIsa::PC_BITS)] || FpgaRom::PAD
  end

  # ROM のデータ (1語 4バイト、バイト j は bit 8j から) の len バイトから String を作る
  def rom_string(addr, len)
    @stats[:string] += 1
    p = new_array(Array.new(len), FpgaIsa::CLS_STRING)
    len.times { |k| @heap[p + 4 + k] = int((rom_word(addr + k / 4) >> (8 * (k % 4))) & 0xFF) }
    [FpgaIsa::TAG_OBJ, p]
  end

  def proc?(r)
    ref?(r) && obj_class(r) == FpgaIsa::CLS_PROC
  end

  def ref?(r)
    r[0] == FpgaIsa::TAG_OBJ
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

  def core_error!(kind, a1 = NIL, a2 = NIL, base = nil)
    raise CoreError.new(kind, a1, a2, base)
  end

  # コアの実行時エラーを例外にする: 例外の表があれば、フレームの上 (fn、ENTER は nregs から) に
  # [種類, 詳細1, 詳細2] を置いて Integer#__core_error を呼ぶ (書き込みはトレースに出さない)。できなければエラー停止
  def core_error(pc, e)
    return :error if @hcount.zero?
    s = e.base || @fn
    return :error unless @bp + s + 3 < @regs.size
    @stats[:core_error] += 1
    @regs[@bp + s] = int(e.kind)
    @regs[@bp + s + 1] = e.a1
    @regs[@bp + s + 2] = e.a2
    r = lookup(FpgaIsa::CLS_INT, FpgaIsa::OP_SYMS.index("__core_error"))
    return :error unless r && (r[0] >> 14) == FpgaIsa::TGT_PC && @stack.size < FpgaIsa::STACK_DEPTH
    @call_kw = 0
    frame(pc, s, 2, false, r[1])
    r[0] & 0x3FFF
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
  # コールスタックの Proc と env (底から、1段ごとに Proc、env の順)、今の Proc、今の env、exc、xval。ハードウェアも同じ順に写す
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
    @exc = forward(@exc)
    @xval = forward(@xval)
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
  def new_array(values, cls = FpgaIsa::CLS_ARRAY)
    cap = values.size
    p = alloc(4 + cap)
    @heap[p] = hdr(cls, 2)
    @heap[p + 1] = int(cap)
    @heap[p + 2] = [FpgaIsa::TAG_OBJ, p + 3]
    @heap[p + 3] = hdr(FpgaIsa::CLS_DATA, cap)
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
      @heap[d] = hdr(FpgaIsa::CLS_DATA, newcap)
      newcap.times { |k| @heap[d + 1 + k] = k < len ? @heap[old + 1 + k] : NIL }
      @heap[a[1] + 2] = [FpgaIsa::TAG_OBJ, d]
    end
    d = ary_data(a)
    (len...i).each { |k| @heap[d + 1 + k] = NIL }
    @heap[d + 1 + i] = reg(rv)
    @heap[a[1] + 1] = int(i + 1) if i >= len
  end

  # Proc: 見出し p、{先頭 pc | 引数の数 << 16 | lambda << 23 | nregs << 24}、作ったフレームの env、外側の Proc、
  # 作ったフレームの self。今のフレームに env が無ければ、Proc と一緒に1回で確保する (env が先、中身は nil)
  def new_proc(entry_word)
    fresh = @env[0] == FpgaIsa::TAG_NIL
    p = alloc((fresh ? 2 + @fn : 0) + 5)
    if fresh
      @heap[p] = hdr(FpgaIsa::CLS_ENV, 1 + @fn)
      @heap[p + 1] = int(@bp)
      @fn.times { |i| @heap[p + 2 + i] = NIL }
      @env = [FpgaIsa::TAG_OBJ, p]
      p += 2 + @fn
    end
    @heap[p] = hdr(FpgaIsa::CLS_PROC, 4)
    @heap[p + 1] = int(entry_word)
    @heap[p + 2] = @env
    @heap[p + 3] = @cp
    @heap[p + 4] = @regs[@bp]
    p
  end

  # ---- メソッド表

  # 値のクラスの番号 (Class の即値はそのメタクラス)
  def class_of(v)
    case v[0]
    when FpgaIsa::TAG_NIL then FpgaIsa::CLS_NIL
    when FpgaIsa::TAG_FALSE then FpgaIsa::CLS_FALSE
    when FpgaIsa::TAG_TRUE then FpgaIsa::CLS_TRUE
    when FpgaIsa::TAG_INT then FpgaIsa::CLS_INT
    when FpgaIsa::TAG_SYM then FpgaIsa::CLS_SYM
    when FpgaIsa::TAG_CLASS then FpgaIsa::META | (v[1] & 0x7FFF)
    else obj_class(v)
    end
  end

  # (クラス, シンボル) の飛び先。表の空きか、表を一周したら nil
  def probe(cls, sym)
    mask = @tsize - 1
    h = FpgaIsa.table_hash(cls, sym, mask)
    @tsize.times do |i|
      w = @rom[(@tbase + ((h + i) & mask)) % (1 << FpgaIsa::PC_BITS)] || FpgaRom::PAD # ROM の大きさで折り返す
      return nil if w == FpgaRom::PAD
      return w & 0xFFFF if (w >> 32) == cls && ((w >> 16) & 0xFFFF) == sym
    end
    nil
  end

  # メソッド探索: [飛び先, 見つかったクラス] か nil。見つからなければ親クラス (SUPER_SYM の飛び先) へ進み、
  # MAX_SUPER_DEPTH - 1 段より先へは行かない (コアと同じ数え方)。super_first は親から探し始める (super)、
  # walk = false は親をたどらない (is_a? と new のインスタンス変数の数)
  def lookup(cls, sym, super_first: false, walk: true)
    return nil if @tsize.zero?
    depth = 0
    sup = super_first
    loop do
      if sup
        s = probe(cls, FpgaIsa::SUPER_SYM)
        return nil unless s
        return nil if depth == FpgaIsa::MAX_SUPER_DEPTH - 1
        cls = s
        depth += 1
        sup = false
        @stats[:super] += 1
      else
        t = probe(cls, sym)
        return [t, cls] if t
        return nil unless walk
        sup = true
      end
    end
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

  # フレームを1つ畳む。@popped_ctor は畳んだフレームが new の initialize だったか
  def pop_frame
    detach
    pc, @bp, @cp, @env, @fn, @mcls, @popped_ctor = @stack.pop
    pc
  end

  # ---- 実行

  def execute(step, pc, op, a, b, c)
    name = FpgaIsa::OPS[op]&.name
    return :error unless name && FpgaIsa.supported?(name)
    nxt = pc + 1
    return :error if !ok?(a) && !%w[NOP JMP RETNIL STOP TABLE].include?(name)

    case name
    when "NOP" then nil
    when "MOVE" then set(step, a, reg(b))
    when "LOADI8"   then set(step, a, int(b & 0xFF))
    when "LOADINEG" then set(step, a, int(-(b & 0xFF)))
    when "LOADI__1" then set(step, a, int(-1))
    when /\ALOADI_(\d)\z/ then set(step, a, int(Regexp.last_match(1).to_i))
    when "LOADI16"  then set(step, a, int(sext16(b)))
    when "LOADI32"  then set(step, a, int((b << 16) | c))
    when "LOADNIL" then set(step, a, NIL)
    when "TDEF", "SDEF" then set(step, a, [FpgaIsa::TAG_SYM, b])
    when "CLASS" then set(step, a, [FpgaIsa::TAG_CLASS, b])
    when "TABLE"
      fault! if a > FpgaIsa::PC_BITS
      @tsize = 1 << a
      @tbase = b
      @symtab = c
    when "HTABLE"
      @hbase = b
      @hcount = c
    when "EXEC"
      fault! unless ok?(a + 1)
      @call_kw = 0
      frame(pc, a, 0, false, @mcls)
      return b
    when "SUPER"
      @stats[:super_call] += 1
      # 今のメソッドが見つかったクラスの親から、同じ名前 (b) を引く。受け手は self、ブロックの枠はそのまま渡す
      argc = c & 0x7F
      @call_kw = (c >> 8) & 1
      fault! unless ok?(a + window(argc) + @call_kw)
      @regs[@bp + a] = @regs[@bp]
      r = lookup(@mcls, b, super_first: true)
      core_error!(FpgaIsa::CERR_NOMETHOD, [FpgaIsa::TAG_SYM, b], reg(a)) unless r
      return dispatch(step, pc, a, argc, true, r[0], r[1])
    when "GETIV"
      # (self のクラス, @名前) を引く。無ければ nil
      r = lookup(class_of(@regs[@bp]), b)
      if r
        fault! unless (r[0] >> 14) == FpgaIsa::TGT_IVAR
        set(step, a, @heap[ivar_addr(@regs[@bp], r[0] & 0x3FFF)])
      else
        set(step, a, NIL)
      end
    when "SETIV"
      r = lookup(class_of(@regs[@bp]), b)
      fault! unless r && (r[0] >> 14) == FpgaIsa::TGT_IVAR
      @heap[ivar_addr(@regs[@bp], r[0] & 0x3FFF)] = reg(a) # ヒープへの書き込みはトレースに出さない
    when "LOADSYM" then set(step, a, [FpgaIsa::TAG_SYM, b])
    when "LOADF"
      # Float のリテラル: ROM のデータの2語 (上位 32bit、下位 32bit) から箱を作る
      put_float(step, a, bits_float(rom_word(b) & MASK, rom_word(b + 1) & MASK))
    when "STRING"
      fault! unless ok?(a)
      set(step, a, rom_string(b, c))
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
    when "ADD", "SUB", "MUL", "DIV", "EQ", "LT", "LE", "GT", "GE"
      t = binop(step, pc, name, a)
      return t if t
    when "ADDI", "SUBI"
      d = b & 0xFF
      unless int?(reg(a))
        # 整数でなければ R[a+1] = b にして + / - を送る (mruby と同じ)
        fault! unless ok?(a + 1)
        @regs[@bp + a + 1] = int(d)
        return send_op(step, pc, a, name == "ADDI" ? "+" : "-", 1)
      end
      set(step, a, int(name == "ADDI" ? reg(a)[1] + d : reg(a)[1] - d))
    when "ADDILV", "SUBILV"
      fault! unless int?(reg(a))
      d = c & 0xFF
      set(step, a, int(name == "ADDILV" ? reg(a)[1] + d : reg(a)[1] - d))
    when "SEND", "SEND0" then return send(step, pc, a, b, c, false)
    when "SSEND", "SSEND0" then return send(step, pc, a, b, c, true)
    when "ENTER" then return enter(pc, a, b, c)
    when "RETURN", "RETNIL"
      v = name == "RETURN" ? reg(a) : NIL
      # 例外の表があれば、ensure に覆われていないかを見ながら戻る
      return @hcount.zero? ? ret(step, v) : unwind(step, pc, FpgaIsa::BRK_RET, @bp, v)
    when "EXCEPT"
      set(step, a, @exc)
      @exc = NIL
    when "RESCUE"
      # R[b] = R[a].is_a?(R[b]) (ISA の行を1回引く)。巻き戻しの塊はどのクラスでもない (表に行が無い)
      y = reg(b)
      fault! unless y[0] == FpgaIsa::TAG_CLASS
      set(step, b, bool(!lookup(FpgaIsa::ISA_BIT | class_of(reg(a)), y[1], walk: false).nil?))
    when "RAISEIF"
      x = reg(a)
      return nxt if x == NIL
      return redispatch(step, pc, x) if brk?(x)
      @exc = x
      return unwind(step, pc, :raise, 0, NIL)
    when "JMPUW" then return unwind(step, pc, FpgaIsa::BRK_JUMP, b, NIL)
    when "STOP" then return :halt
    when "BREAK" then return brk(step, pc, a, b, c)
    when "RETURN_BLK" then return return_blk(step, pc, a, c)
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
      set(step, a, [FpgaIsa::TAG_OBJ, new_proc((b & 0xFFFF) | ((c & 0x80) << 16))])
    when "BLKCALL"
      @call_kw = 0
      return blkcall(pc, a, b, false)
    when "ARYCAT"
      # R[a] = splat(R[a]) + splat(R[a+1])。splat: 配列は中身、nil は空、Proc と即値は1要素。
      # ほかのオブジェクトは to_a を持つかもしれないので止める
      fault! unless ok?(a + 1)
      x = reg(a)
      y = reg(a + 1)
      fault! unless x == NIL || ary?(x)
      fault! if ref?(y) && !ary?(y) && !proc?(y)
      n1 = x == NIL ? 0 : ary_len(x)
      n2 = ary?(y) ? ary_len(y) : (y == NIL ? 0 : 1)
      p = new_array(Array.new(n1 + n2))
      x = reg(a) # 確保で GC が走ると動く
      y = reg(a + 1)
      n1.times { |k| @heap[p + 4 + k] = ary_get(x, k) }
      n2.times { |k| @heap[p + 4 + n1 + k] = ary?(y) ? ary_get(y, k) : y }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    when "ARYPUSH"
      # R[a] = R[a] + [R[a+1] .. R[a+b]] (新しい配列にする。R[a] は同じ式の中で作った配列だけ)
      fault! unless ok?(a + b) && ary?(reg(a))
      n1 = ary_len(reg(a))
      p = new_array(Array.new(n1 + b))
      x = reg(a)
      n1.times { |k| @heap[p + 4 + k] = ary_get(x, k) }
      b.times { |k| @heap[p + 4 + n1 + k] = reg(a + 1 + k) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    when "APOST"
      # a, *r, x = v: R[a] = v[b...len-c] (配列)、R[a+1..a+c] = 後ろの c 個。配列でなければ [v] として
      fault! unless ok?(a + c)
      len = ary?(reg(a)) ? ary_len(reg(a)) : 1
      rn = [len - b - c, 0].max
      p = new_array(Array.new(rn))
      v = reg(a)
      el = ->(j) { ary?(v) ? ary_get(v, j) : v }
      rn.times { |k| @heap[p + 4 + k] = el.(b + k) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
      c.times do |i|
        j = len > b + c ? len - c + i : b + i
        set(step, a + 1 + i, j < len ? el.(j) : NIL)
      end
    when "ARGARY"
      # 引数なしの super: R[a] = 今のメソッドの引数の配列 (前 m1、残り、後ろ m2)、R[a+1] = ブロック (先に、トレースなし)
      m1 = (b >> 11) & 0x3F
      r = (b >> 10) & 1
      m2 = (b >> 5) & 0x1F
      fault! unless a > m1 + r + m2 + 1 && ok?(a + 1)
      fault! if r == 1 && !ary?(reg(m1 + 1))
      @regs[@bp + a + 1] = reg(m1 + r + m2 + 1)
      rl = r == 1 ? ary_len(reg(m1 + 1)) : 0
      p = new_array(Array.new(m1 + rl + m2))
      m1.times { |k| @heap[p + 4 + k] = reg(1 + k) }
      rl.times { |k| @heap[p + 4 + m1 + k] = ary_get(reg(m1 + 1), k) }
      m2.times { |k| @heap[p + 4 + m1 + rl + k] = reg(m1 + r + 1 + k) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    when "ARRAY"
      fault! unless b.zero? || ok?(a + b - 1)
      p = new_array(Array.new(b))
      b.times { |i| @heap[p + 4 + i] = reg(a + i) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    when "ARRAY2"
      fault! unless c.zero? || ok?(b + c - 1)
      p = new_array(Array.new(c))
      c.times { |i| @heap[p + 4 + i] = reg(b + i) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    when "GETIDX"
      # 配列を整数で引く時だけその場で。ほか (Range で切り出すなど) は [] を送る
      return send_op(step, pc, a, "[]", 1) unless ary?(reg(a)) && int?(reg(a + 1))
      set(step, a, index(reg(a), reg(a + 1)))
    when "GETIDX0"
      v = reg(b)
      unless ary?(v)
        # 配列でなければ R[a] = 受け手、R[a+1] = 0 にして [] を送る
        fault! unless ok?(a + 1)
        @regs[@bp + a] = v
        @regs[@bp + a + 1] = int(0)
        return send_op(step, pc, a, "[]", 1)
      end
      set(step, a, index(v, int(0)))
    when "AREF" # 多重代入: 配列なら R[b][c]、配列でなければ c = 0 の時だけ R[b] 自身、ほかは nil
      v = reg(b)
      @stats[:aref] += 1
      set(step, a, ary?(v) ? index(v, int(c & 0xFF)) : (c.zero? ? v : NIL))
    when "SETIDX"
      reg(a + 2)
      return send_op(step, pc, a, "[]=", 2) unless ary?(reg(a))
      aset(a)
    end
    nxt
  end

  # R[a][R[a+1]] = R[a+2] (R[a] は配列)
  def aset(a)
    arr = reg(a)
    idx = reg(a + 1)
    reg(a + 2)
    fault! unless int?(idx)
    i = signed(idx[1])
    i += ary_len(arr) if i < 0
    fault! if i < 0 || i >= 0x10000
    ary_set(a, i, a + 2)
  end

  # 演算の落ち先: isa.rb の OP_SYMS の番号でメソッドを送る
  def send_op(step, pc, a, name, argc)
    send(step, pc, a, FpgaIsa::OP_SYMS.index(name), argc, false)
  end

  def index(arr, idx)
    fault! unless (ary?(arr) || str?(arr)) && int?(idx)
    i = signed(idx[1])
    len = ary_len(arr)
    i += len if i < 0
    i >= 0 && i < len ? ary_get(arr, i) : NIL
  end

  # メソッドの呼び出し: R[a] (SSEND は R0 を R[a] に写してから) のクラスで b を引く。c = 引数の数 | ブロックを渡す印 << 7。
  # メソッドなら新しいフレーム (底は bp + a、R0 = 受け手、R[1..引数の数] = 引数、その次がブロックの枠)、primitive ならその場で
  # c の bit 8 (KW) はキーワード引数の Hash を R[window(argc)] に持つ印。ブロックの枠はその次 (@call_kw でフレームへ渡す)
  def send(step, pc, a, sym, c, self_call)
    argc = c & 0x7F
    @call_kw = (c >> 8) & 1
    fault! unless ok?(a + window(argc) + @call_kw)
    @regs[@bp + a] = @regs[@bp] if self_call # self を受け手の場所へ (トレースに出さない)
    r = lookup(class_of(reg(a)), sym)
    core_error!(FpgaIsa::CERR_NOMETHOD, [FpgaIsa::TAG_SYM, sym], reg(a)) unless r
    dispatch(step, pc, a, argc, (c & 0x80) != 0, r[0], r[1])
  end

  # 見つかった飛び先へ: メソッド (フレームを作る)、primitive、インスタンス変数の読み書き (attr_*)
  def dispatch(step, pc, a, argc, blk, t, found)
    @stats[:found] += 1
    tgt = t & 0x3FFF
    case t >> 14
    when FpgaIsa::TGT_PRIM then prim(step, pc, tgt, a, argc, blk)
    when FpgaIsa::TGT_PC
      frame(pc, a, argc, blk, found)
      tgt
    when FpgaIsa::TGT_IVAR
      fault! unless argc.zero? && @call_kw.zero?
      set(step, a, @heap[ivar_addr(reg(a), tgt)])
      pc + 1
    else
      fault! unless argc == 1 && @call_kw.zero?
      @heap[ivar_addr(reg(a), tgt)] = reg(a + 1)
      set(step, a, reg(a + 1))
      pc + 1
    end
  end

  # オブジェクト (Object かプログラムのクラスのインスタンス) の i 番目のインスタンス変数の語アドレス
  def ivar_addr(obj, i)
    @stats[:ivar] += 1
    fault! unless ref?(obj)
    cls = obj_class(obj)
    fault! unless FpgaIsa.instantiable?(cls)
    fault! if i >= (@heap[obj[1]][1] & 0xFFFF)
    obj[1] + 1 + i
  end

  # メソッドのフレームに入る。残りのレジスタは呼ばれた側の ENTER が埋める。ブロックを渡さなければその枠は nil。
  # mcls は見つかったクラス (super の起点)、ctor は new の initialize (戻り値で R0 を上書きしない)
  def frame(pc, a, argc, blk, mcls, ctor = false)
    fault! if @stack.size >= FpgaIsa::STACK_DEPTH
    @stack.push([pc + 1, @bp, @cp, @env, @fn, @mcls, ctor])
    @bp += a
    @regs[@bp + window(argc) + @call_kw] = NIL unless blk
    @cp = NIL
    @env = NIL
    @fn = 0
    @mcls = mcls
    @argc = argc
    @kw = @call_kw
  end

  # 引数の後ろのブロックの枠の位置 (argc = 15 は R[1] に引数の配列)
  def window(argc)
    argc == 15 ? 2 : argc + 1
  end

  # Proc を呼ぶ (yield / blk.call / iterator)。R[a] の Proc を、R[a+1].. の n 個の値で (15 は配列)。
  # フレームの R0 は Proc を作った時の self、ブロックの枠は blk でなければ nil。数の検査と並べ替えは Proc の先頭の ENTER
  def blkcall(pc, a, n, blk)
    pr = reg(a)
    fault! unless proc?(pr)
    fault! unless ok?(a + window(n) + @call_kw) && @stack.size < FpgaIsa::STACK_DEPTH
    @stack.push([pc + 1, @bp, @cp, @env, @fn, @mcls, false])
    @bp += a
    @regs[@bp] = @heap[pr[1] + 4]
    @regs[@bp + window(n) + @call_kw] = NIL unless blk
    @cp = pr
    @env = NIL
    @fn = 0
    @argc = n
    @kw = @call_kw
    @heap[pr[1] + 1][1] & 0xFFFF
  end

  # ENTER (mruby 3.3 の OP_ENTER と同じ並べ方)。a = 必須 m1、b = nregs、c = 省略可能 o | 残り r << 5 | 後ろの必須 m2 << 6。
  # 引数は R[1..argc]、argc = 15 なら R[1] の配列の中身 (ブロックの枠は R[2])。メソッドと lambda は数を調べ、
  # proc は調べずに、引数が1つの配列で len > 1 なら展開する。並べ終えると R[1..m1+o] 前、R[m1+o+1] 残りの配列、
  # その後ろに m2、R[len+1] ブロック、その先 nregs まで nil。省略可能な引数は、渡された数だけ後ろの JMP の表を飛ばす。
  # 書き込みはトレースに出さない (ハードウェアも同じ順に書く)
  # キーワード引数 (c の bit 11 = kd、PicoRuby の vm_op_enter と同じ): 呼び出しの印 @kw があれば Hash は R[window(argc)]。
  # kd でなければその Hash を最後の引数として数え (14 個以上は止める)、kd なら R[len+1] に置く (無ければ空の Hash を作る)。
  # ブロックは R[len+kd+1]
  def enter(pc, a, b, c)
    m1 = a
    o = c & 0x1F
    r = (c >> 5) & 1
    m2 = (c >> 6) & 0x1F
    kd = (c >> 11) & 1
    len = m1 + o + r + m2
    fault! if @bp + [b, len + kd + 2].max > @regs.size
    argc = @argc
    kw = @kw || 0
    if kw == 1 && kd.zero?
      fault! if argc >= 14
      argc += 1
      kw = 0
    end
    kidx = argc == 15 ? 2 : argc + 1 # 印がある時の Hash の場所
    strict = !proc?(@cp) || lambda?(@cp)
    heap = argc == 15 || (!strict && argc == 1 && len > 1 && ary?(reg(1)))
    fault! if heap && !ary?(reg(1))
    cnt = heap ? ary_len(reg(1)) : argc
    core_error!(FpgaIsa::CERR_ARGNUM, int(cnt), int(m1 + m2), b) if strict && (cnt < m1 + m2 || (r.zero? && cnt > m1 + o + m2))
    if cnt < len
      mlen = cnt < m1 + m2 ? [cnt - m1, 0].max : m2
      front = cnt - mlen
      ps = front
      pm = mlen
      rn = 0
      skip = o > 0 && cnt > m1 + m2 ? cnt - m1 - m2 : 0
      desc = !heap # 後ろの必須は上へ動く
    else
      rn = r.zero? ? 0 : cnt - m1 - o - m2
      front = m1 + o
      ps = m1 + o + rn
      pm = m2
      skip = o
      desc = false
    end
    # 1. 残りの配列と (kd で Hash が渡されなければ) 空の Hash を1回で確保する (GC が走ってよい。まだ何も動かしていない)
    mkhash = kd == 1 && kw.zero?
    rsize = r == 1 ? 4 + rn : 0
    if r == 1 || mkhash
      q = alloc(rsize + (mkhash ? 13 : 0))
      if r == 1
        @stats[:rest] += 1
        p = q
        @heap[p] = hdr(FpgaIsa::CLS_ARRAY, 2)
        @heap[p + 1] = int(rn)
        @heap[p + 2] = [FpgaIsa::TAG_OBJ, p + 3]
        @heap[p + 3] = hdr(FpgaIsa::CLS_DATA, rn)
        rn.times { |k| @heap[p + 4 + k] = heap ? ary_get(reg(1), m1 + o + k) : reg(1 + m1 + o + k) }
      end
      if mkhash
        @stats[:kwhash] += 1
        h = q + rsize
        new_hash_at(h)
      end
    end
    # 2. 以後は確保しない。ブロック、キーワードの Hash と、配列から読むならその中身の位置を覚えてから動かす
    blk = @regs[@bp + (heap ? 2 : argc + 1) + kw]
    kdict = kd.zero? ? nil : (kw == 1 ? @regs[@bp + kidx] : [FpgaIsa::TAG_OBJ, h])
    src = heap ? reg(1) : nil
    get = ->(j) { heap ? ary_get(src, j) : @regs[@bp + 1 + j] }
    (desc ? (m2 - 1).downto(0) : 0.upto(m2 - 1)).each do |k|
      @regs[@bp + m1 + o + r + 1 + k] = k < pm ? get.(ps + k) : NIL
    end
    ((heap ? 0 : front)...(m1 + o)).each { |i| @regs[@bp + 1 + i] = i < front ? get.(i) : NIL }
    @regs[@bp + m1 + o + 1] = [FpgaIsa::TAG_OBJ, p] if r == 1
    @regs[@bp + len + 1] = kdict if kd == 1
    @regs[@bp + len + kd + 1] = blk
    ((len + kd + 2)...b).each { |i| @regs[@bp + i] = NIL }
    @fn = b
    @stats[:enter_skip] += 1 if skip > 0
    pc + 1 + skip
  end

  # 戻り: 呼び出し先の R0 (= 呼び出し元の R[a]) に値を置いて戻る。フレームが無ければ停止
  def ret(step, value)
    return :halt if @stack.empty?
    callee = @bp
    pc = pop_frame
    set_abs(step, callee, value) unless @popped_ctor # initialize の戻り値は捨てる (R0 = new したオブジェクト)
    pc
  end

  # break。c = 0: iterator に直接渡したブロック。フレームを1つ畳んで b (iterator の出口) へ。
  # c = 1: メソッドや Proc に渡したブロック。Proc を作ったフレームへ戻るまで畳み、その呼び出しの結果にする
  # (畳むフレームが ensure に覆われていれば、そこで ensure を走らせてから続ける。unwind)
  def brk(step, pc, a, b, c)
    value = reg(a)
    fault! if @stack.empty?
    if c.zero?
      return unwind(step, pc, FpgaIsa::BRK_BRK0, b, value) unless @hcount.zero?
      ret(step, value)
      return b
    end
    if lambda?(@cp) # lambda の中の break は lambda から戻る
      @stats[:lambda_exit] += 1
      return @hcount.zero? ? ret(step, value) : unwind(step, pc, FpgaIsa::BRK_RET, @bp, value)
    end
    unwind(step, pc, FpgaIsa::BRK_BRK, frame_base(1), value)
  end

  # ブロックの中の return: ブロックを囲むメソッド (深さ c のフレーム) まで畳み、そのメソッドから戻る。
  # 途中に lambda があれば、一番内側の lambda から戻る (深さ d の Proc が lambda なら、深さ d のフレーム)
  def return_blk(step, pc, a, c)
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
    unwind(step, pc, FpgaIsa::BRK_RET, frame_base(d), value)
  end

  # ---- 例外と巻き戻し (PicoRuby の vm.c の L_RAISE / UNWIND_ENSURE / THROW_TAGGED_BREAK と同じ意味)

  def brk?(v)
    ref?(v) && obj_class(v) == FpgaIsa::CLS_BRK
  end

  # 例外の表で pc を覆う handler (表の順に最初のもの)。ensure_only は ensure だけ。[飛び先, begin, end] か nil
  def find_handler(pc, ensure_only)
    @hcount.times do |i|
      op, a, b, c = FpgaRom.unpack(rom_word(@hbase + i))
      v = (op << 8) | a
      next if ensure_only && (v >> 15) != FpgaIsa::CATCH_ENSURE
      return [v & ((1 << FpgaIsa::PC_BITS) - 1), b, c] if pc >= b && pc < c
    end
    nil
  end

  # 巻き戻し。kind は :raise (@exc を投げる) か巻き戻しの塊の種類 (isa.rb の BRK_*)、target はその行き先、value は運ぶ値。
  # 今のフレームの pc (呼び出し元は戻り先 - 1) を覆う handler を探し、無ければフレームを畳んで (env は写す) 呼び出し元で探す。
  # :raise は rescue と ensure、ほかは ensure だけを探す。ensure が見つかれば、巻き戻しの塊 (brk、無ければ作る) を
  # @exc に置いてそこへ飛ぶ (ensure の最後の RAISEIF が redispatch で続ける)。JUMP は行き先がその ensure の外の時だけ
  def unwind(step, pc, kind, target, value, brk = nil)
    @xval = value
    xpc = pc
    loop do
      h = find_handler(xpc, kind != :raise)
      if h
        @stats[:handler] += 1
        if kind == :raise
          @xval = NIL
          return h[0]
        end
        if kind != FpgaIsa::BRK_JUMP || target < h[1] || target > h[2]
          unless brk
            p = alloc(3) # GC が走ってよい (@xval は根)
            @heap[p] = hdr(FpgaIsa::CLS_BRK, 2)
            @heap[p + 1] = int((kind << 16) | target)
            @heap[p + 2] = @xval
            brk = [FpgaIsa::TAG_OBJ, p]
          end
          @exc = brk
          @xval = NIL
          return h[0]
        end
      end
      case kind
      when :raise
        fault! if @stack.empty? # 一番外まで捕まらなかった
        @stats[:raise_pop] += 1
        xpc = (pop_frame - 1) & ((1 << FpgaIsa::PC_BITS) - 1)
        next
      when FpgaIsa::BRK_JUMP
        return finish(target)
      when FpgaIsa::BRK_RET
        if @bp == target
          return :halt if @stack.empty?
          callee = @bp
          ret_pc = pop_frame
          set_abs(step, callee, @xval) unless @popped_ctor # initialize の戻り値は捨てる
          return finish(ret_pc)
        end
      when FpgaIsa::BRK_BRK
        fault! if @stack.empty?
        if @stack.last[1] == target
          callee = @bp
          ret_pc = pop_frame
          set_abs(step, callee, @xval)
          return finish(ret_pc)
        end
      else # BRK0
        fault! if @stack.empty?
        callee = @bp
        pop_frame
        set_abs(step, callee, @xval)
        return finish(target)
      end
      fault! if @stack.empty?
      xpc = (pop_frame - 1) & ((1 << FpgaIsa::PC_BITS) - 1)
    end
  end

  # 巻き戻しを終えて pc へ
  def finish(pc)
    @exc = NIL
    @xval = NIL
    pc
  end

  # ensure の最後の RAISEIF が巻き戻しの塊を受けた: その pc から続ける
  def redispatch(step, pc, x)
    @stats[:redispatch] += 1
    w = @heap[x[1] + 1][1]
    unwind(step, pc, w >> 16, w & 0xFFFF, @heap[x[1] + 2], x)
  end

  # 空の Hash を h から 13 語に作る (プレリュードの Hash の形: @keys @vals @default @default_proc。変換器が確かめる)
  def new_hash_at(h)
    @heap[h] = hdr(FpgaIsa::CLS_HASH, 4)
    @heap[h + 1] = [FpgaIsa::TAG_OBJ, h + 5]
    @heap[h + 2] = [FpgaIsa::TAG_OBJ, h + 9]
    @heap[h + 3] = NIL
    @heap[h + 4] = NIL
    [5, 9].each do |x|
      @heap[h + x] = hdr(FpgaIsa::CLS_ARRAY, 2)
      @heap[h + x + 1] = int(0)
      @heap[h + x + 2] = [FpgaIsa::TAG_OBJ, h + x + 3]
      @heap[h + x + 3] = hdr(FpgaIsa::CLS_DATA, 0)
    end
  end

  def shift_left(x, s)
    return int(0) if s >= FpgaIsa::INT_BITS
    return int(x < 0 ? -1 : 0) if s <= -FpgaIsa::INT_BITS
    s >= 0 ? int(x << s) : int(x >> -s)
  end

  # primitive (isa.rb の PRIMS)。受け手の型が違えばエラー (表が壊れていても同じ結果になるように)
  def prim(step, pc, id, a, argc, blk = false)
    pr = FpgaIsa::PRIMS[id]
    fault! unless pr
    core_error!(FpgaIsa::CERR_ARGNUM, int(argc), int(pr[2])) unless pr[2] == -1 || pr[2] == argc
    name = pr[3]
    fault! unless @call_kw.zero? || name == "CALL" || name == "NEW" # キーワード引数を受ける primitive は new と call だけ
    return blkcall(pc, a, argc, blk) if name == "CALL"
    return new_object(step, pc, a, argc, blk) if name == "NEW"
    return io_prim(step, pc, name, a) if name == "IOREAD" || name == "IOWRITE"
    return float_prim(step, pc, name, a) if FLOAT_PRIMS.include?(name)
    if name == "RAISE"
      @exc = reg(a + 1)
      return unwind(step, pc, :raise, 0, NIL)
    end
    x = reg(a)
    case name
    when "ISA", "KINDOF"
      # (ISA_BIT | 受け手のクラス, 引数のクラス) があるか (親はたどらない)
      y = reg(a + 1)
      fault! unless y[0] == FpgaIsa::TAG_CLASS
      set(step, a, bool(!lookup(FpgaIsa::ISA_BIT | class_of(x), y[1], walk: false).nil?))
      return pc + 1
    when "RESPOND"
      y = reg(a + 1)
      fault! unless y[0] == FpgaIsa::TAG_SYM
      set(step, a, bool(!lookup(class_of(x), y[1]).nil?))
      return pc + 1
    when "AGET"
      fault! unless ary?(x)
      set(step, a, index(x, reg(a + 1)))
      return pc + 1
    when "ASET"
      fault! unless ary?(x)
      aset(a)
      set(step, a, reg(a + 2)) # 伸ばす時の GC で動くので後で読む
      return pc + 1
    when "OEQ", "SAME"
      set(step, a, bool(x == reg(a + 1))) # 同じものか
      return pc + 1
    when "IADD", "ISUB", "IMUL", "IDIV", "ILT", "ILE", "IGT", "IGE"
      # 整数の演算をメソッドとして呼んだもの (self * 2 など)。引数も整数でなければエラー
      fault! unless int?(x)
      if float?(reg(a + 1)) # Integer と Float は Float で計算する
        float_arith(step, a, name.sub(/\AI/, "F"), signed(x[1]).to_f, fval(reg(a + 1)))
        return pc + 1
      end
      core_error!(%w[ILT ILE IGT IGE].include?(name) ? FpgaIsa::CERR_COMPARE : FpgaIsa::CERR_TYPE, reg(a + 1), x) unless int?(reg(a + 1))
      binop(step, pc, { "IADD" => "ADD", "ISUB" => "SUB", "IMUL" => "MUL", "IDIV" => "DIV",
                        "ILT" => "LT", "ILE" => "LE", "IGT" => "GT", "IGE" => "GE" }[name], a)
      return pc + 1
    when "IEQ"
      fault! unless int?(x)
      y = reg(a + 1)
      set(step, a, bool(float?(y) ? signed(x[1]).to_f == fval(y) : x == y))
      return pc + 1
    when "CLASSOF"
      c = class_of(x)
      set(step, a, [FpgaIsa::TAG_CLASS, (c & FpgaIsa::META).zero? ? c : FpgaIsa::CLS_CLASS])
      return pc + 1
    end
    if name == "LAMBDA"
      b = reg(a + 1) # 引数 0 個なのでブロックの枠
      fault! unless proc?(b)
      @heap[b[1] + 1] = int(@heap[b[1] + 1][1] | (1 << 23))
      set(step, a, b)
      return pc + 1
    end
    builtin(step, name, a, argc)
    pc + 1
  end

  # __io_read(addr) / __io_write(addr, value): 番地 0..3 は GETGV / SETGV と同じポート、0x100 から上はデバイス
  # (devices.rb)。書き込みはトレースの O 行 (ポート番号 = 番地)。デバイスには Integer だけを書ける
  def io_prim(step, pc, name, a)
    addr = reg(a + 1)
    fault! unless int?(addr) && addr[1] < 0x10000
    n = addr[1]
    if name == "IOREAD"
      v = if n < FpgaIoMap::NPORTS
            FpgaIoMap::IN_MASK[n] == 1 ? input(step, n) : @io[n]
          elsif FpgaDevices.device?(n)
            r = @dev.read(n, step, vtime(step, true))
            @stats[:irq_event] += 1 if n == FpgaDevices::IRQ_EVENT && r != MASK
            r.nil? ? NIL : int(r)
          else
            NIL
          end
      set(step, a, v)
      return pc + 1
    end
    v = reg(a + 2)
    fault! if ref?(v) || (n < FpgaIoMap::NPORTS && FpgaIoMap::IN_MASK[n] == 1)
    core_error!(FpgaIsa::CERR_TYPE, v) if FpgaDevices.device?(n) && !int?(v)
    @io[n] = v if n < FpgaIoMap::NPORTS
    @dev.write(n, v[1], vtime(step, true)) if FpgaDevices.device?(n)
    set(step, a, v) # RTL と同じく W 行が先
    @trace << format("O %d %d %d %08x", step, n, v[0], v[1])
    pc + 1
  end

  # ---- Float (ヒープの箱 [HDR(Float, 2)] [INT 上位 32bit] [INT 下位 32bit] の double)

  FLOAT_PRIMS = %w[FADD FSUB FMUL FDIV FMOD FPOW FLT FLE FGT FGE FEQ FCMP FNEG FTOI FFLOOR FCEIL FROUND FNAN FINF
                   FTOS FFMT FMATH FATAN2 FHYPOT FFMOD I2F STOD].freeze

  def float?(v)
    ref?(v) && obj_class(v) == FpgaIsa::CLS_FLOAT
  end

  def bits_float(hi, lo)
    [hi, lo].pack("NN").unpack1("G")
  end

  def bits_of(f)
    [f].pack("G").unpack1("Q>")
  end

  def float_of_bits(b)
    [b].pack("Q>").unpack1("G")
  end

  def fval(v)
    bits_float(@heap[v[1] + 1][1], @heap[v[1] + 2][1])
  end

  # Integer か Float の値 (ほかは nil)
  def num(v)
    return signed(v[1]).to_f if int?(v)
    float?(v) ? fval(v) : nil
  end

  def put_float(step, a, f)
    p = alloc(3)
    hi, lo = [f].pack("G").unpack("NN")
    @heap[p] = hdr(FpgaIsa::CLS_FLOAT, 2)
    @heap[p + 1] = int(hi)
    @heap[p + 2] = int(lo)
    @stats[:float] += 1
    set(step, a, [FpgaIsa::TAG_OBJ, p])
  end

  # C の fmod (x - trunc(x / y) * y を丸めずに。符号は x)
  def c_fmod(x, y)
    return Float::NAN if y.zero? || x.nan? || y.nan? || x.infinite?
    return x if y.infinite?
    r = x.abs.to_r % y.abs.to_r
    r.zero? ? (x.negative? || (x.zero? && 1.0 / x < 0) ? -0.0 : 0.0) : (x < 0 ? -r.to_f : r.to_f)
  end

  # C の pow (PicoRuby は pow)。CRuby は負の数の分数乗と NaN 乗を Complex にするので、そこだけ C の規則で:
  # 有限の負の数の分数乗は NaN、-Infinity の分数乗は正なら Infinity・負なら 0.0、NaN 乗は x + y (glibc と同じ NaN)
  def c_pow(x, y)
    if x < 0 && (y.nan? || (y.finite? && y != y.floor))
      return x + y if y.nan?
      return y > 0 ? Float::INFINITY : 0.0 if x.infinite?
      return Float::NAN
    end
    x**y
  end

  # 二項の演算か比較 (x、y は Ruby の Float)。F で始まる primitive の名前
  def float_arith(step, a, name, x, y)
    case name
    when "FADD" then put_float(step, a, x + y)
    when "FSUB" then put_float(step, a, x - y)
    when "FMUL" then put_float(step, a, x * y)
    when "FDIV" then put_float(step, a, x / y)
    when "FMOD"
      core_error!(FpgaIsa::CERR_ZERODIV) if y.zero? # CRuby も PicoRuby も 0.0 での % は ZeroDivisionError
      put_float(step, a, x % y)
    when "FPOW" then put_float(step, a, c_pow(x, y))
    when "FLT" then set(step, a, bool(x < y))
    when "FLE" then set(step, a, bool(x <= y))
    when "FGT" then set(step, a, bool(x > y))
    when "FGE" then set(step, a, bool(x >= y))
    end
  end

  # 新しい String (中身は s のバイト)
  def put_string(step, a, s)
    p = new_array(Array.new(s.bytesize), FpgaIsa::CLS_STRING)
    s.bytesize.times { |k| @heap[p + 4 + k] = int(s.getbyte(k)) }
    set(step, a, [FpgaIsa::TAG_OBJ, p])
  end

  def float_prim(step, pc, name, a)
    x = reg(a)
    if name == "I2F"
      fault! unless int?(x)
      put_float(step, a, signed(x[1]).to_f)
      return pc + 1
    end
    if name == "STOD"
      # プレリュードが整えた Float のリテラルの形の文字列だけが来る
      fault! unless str?(x) && ary_len(x) <= 64
      text = Array.new(ary_len(x)) { |k| ary_get(x, k)[1] & 0xFF }.pack("C*")
      fault! unless text.match?(/\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/)
      put_float(step, a, float_of_bits(FpgaFloat.strtod(text)))
      return pc + 1
    end
    fault! unless float?(x)
    xf = fval(x)
    case name
    when "FADD", "FSUB", "FMUL", "FDIV", "FMOD", "FPOW", "FLT", "FLE", "FGT", "FGE"
      y = num(reg(a + 1))
      core_error!(%w[FLT FLE FGT FGE].include?(name) ? FpgaIsa::CERR_COMPARE : FpgaIsa::CERR_TYPE, reg(a + 1), x) if y.nil?
      float_arith(step, a, name, xf, y)
    when "FEQ"
      y = num(reg(a + 1))
      set(step, a, bool(!y.nil? && xf == y))
    when "FCMP"
      y = num(reg(a + 1))
      r = y.nil? ? nil : (xf <=> y)
      set(step, a, r.nil? ? NIL : int(r))
    when "FNEG" then put_float(step, a, -xf)
    when "FTOI"
      core_error!(FpgaIsa::CERR_FLOATDOMAIN, x) if xf.nan? || xf.infinite?
      t = xf.truncate
      core_error!(FpgaIsa::CERR_RANGE, x) if t < -2**31 || t >= 2**31
      set(step, a, int(t))
    when "FFLOOR", "FCEIL", "FROUND"
      r = if !xf.finite? then xf
          elsif name == "FFLOOR" then xf.floor.to_f
          elsif name == "FCEIL" then xf.ceil.to_f
          else xf.round(half: :up).to_f # C の round (0.5 は 0 から遠い方へ)
          end
      r = -0.0 if r.zero? && (xf.negative? || (xf.zero? && 1.0 / xf < 0)) # -0.4.round は -0.0 (C と同じ)
      put_float(step, a, r)
    when "FNAN" then set(step, a, bool(xf.nan?))
    when "FINF"
      r = xf.infinite?
      set(step, a, r.nil? ? NIL : int(r))
    when "FTOS" then put_string(step, a, xf.to_s)
    when "FFMT"
      conv = reg(a + 1)
      prec = reg(a + 2)
      fault! unless int?(conv) && "feEgG".bytes.include?(conv[1]) && int?(prec) && prec[1] <= 20 && xf.finite?
      put_string(step, a, FpgaFloat.fmt(bits_of(xf), conv[1].chr, prec[1]))
    when "FMATH"
      i = reg(a + 1)
      fault! unless int?(i) && i[1] < FpgaIsa::FMATH.size
      r = begin
        Math.send(FpgaIsa::FMATH[i[1]], xf)
      rescue Math::DomainError
        Float::NAN # C の libm と同じ (プレリュードが先に Math::DomainError にする)
      end
      put_float(step, a, r)
    when "FATAN2", "FHYPOT", "FFMOD"
      y = num(reg(a + 1))
      core_error!(FpgaIsa::CERR_TYPE, reg(a + 1), x) if y.nil?
      put_float(step, a, name == "FATAN2" ? Math.atan2(xf, y) : (name == "FHYPOT" ? Math.hypot(xf, y) : c_fmod(xf, y)))
    end
    pc + 1
  end

  # String の primitive (受け手は String、Symbol#to_s は Symbol)。1語に1バイト (Integer 0..255)。範囲の外はエラー
  # (負の添字や範囲の丸めはプレリュードがする)
  def string_prim(step, name, a, x)
    if name == "SYMSTR"
      fault! unless x[0] == FpgaIsa::TAG_SYM
      w = rom_word((@symtab || 0) + x[1])
      return set(step, a, rom_string((w >> 16) & 0xFFFF, w & 0xFFFF))
    end
    fault! unless str?(x)
    len = ary_len(x)
    byte = ->(v) { int?(v) && v[1] <= 0xFF }
    case name
    when "SBYTES" then set(step, a, int(len))
    when "SGETB"
      fault! unless int?(reg(a + 1))
      set(step, a, index(x, reg(a + 1)))
    when "SASET"
      i = reg(a + 1)
      fault! unless int?(i) && i[1] < len && byte.(reg(a + 2))
      ary_set(a, i[1], a + 2)
      set(step, a, reg(a + 2))
    when "SPUSH"
      fault! unless byte.(reg(a + 1)) && len < 0xFFFF
      ary_set(a, len, a + 1)
      set(step, a, reg(a))
    when "SSLICE"
      i = reg(a + 1)
      n = reg(a + 2)
      fault! unless int?(i) && int?(n) && i[1] + n[1] <= len # 負の数は 32bit の大きな値なので外れる
      p = new_array(Array.new(n[1]), FpgaIsa::CLS_STRING)
      src = reg(a) # 確保で GC が走ると動く
      n[1].times { |k| @heap[p + 4 + k] = ary_get(src, i[1] + k) }
      set(step, a, [FpgaIsa::TAG_OBJ, p])
    end
  end

  # Class#new: インスタンス変数の数を (クラス, NIVARS_SYM) で引き (無ければ 0)、確保して R[a] に置き、initialize を送る。
  # Object とプログラムのクラスだけ。initialize が見つからなければそのまま (プレリュードが Object#initialize を持つ)
  def new_object(step, pc, a, argc, blk)
    k = reg(a)
    fault! unless k[0] == FpgaIsa::TAG_CLASS
    id = k[1]
    fault! unless FpgaIsa.instantiable?(id)
    r = lookup(id, FpgaIsa::NIVARS_SYM, walk: false)
    n = r ? r[0] & 0x3FFF : 0
    @stats[:object] += 1
    p = alloc(1 + n)
    @heap[p] = hdr(id, n)
    n.times { |i| @heap[p + 1 + i] = NIL }
    set(step, a, [FpgaIsa::TAG_OBJ, p])
    init = lookup(id, FpgaIsa::OP_SYMS.index("initialize"))
    return pc + 1 unless init
    fault! unless (init[0] >> 14) == FpgaIsa::TGT_PC
    frame(pc, a, argc, blk, init[1], true)
    init[0] & 0x3FFF
  end

  def builtin(step, name, a, argc)
    x = reg(a)
    y = argc == 1 ? reg(a + 1) : nil
    return string_prim(step, name, a, x) if %w[SBYTES SGETB SASET SPUSH SSLICE SYMSTR].include?(name)
    if name == "NAMESYM"
      # (クラス, NAME_SYM) を親をたどらずに引く。無ければ nil
      fault! unless x[0] == FpgaIsa::TAG_CLASS
      r = lookup(x[1], FpgaIsa::NAME_SYM, walk: false)
      return set(step, a, r ? [FpgaIsa::TAG_SYM, r[0]] : NIL)
    end
    if %w[SIZE LENGTH EMPTY FIRST LAST POP PUSH APUSH].include?(name)
      fault! unless ary?(x)
      value = case name
              when "SIZE", "LENGTH" then int(ary_len(x))
              when "EMPTY" then bool(ary_len(x).zero?)
              when "FIRST" then ary_len(x).zero? ? NIL : ary_get(x, 0)
              when "LAST" then ary_len(x).zero? ? NIL : ary_get(x, ary_len(x) - 1)
              when "POP"
                len = ary_len(x)
                if len.zero?
                  NIL
                else
                  @heap[x[1] + 1] = int(len - 1)
                  ary_get(x, len - 1)
                end
              when "PUSH", "APUSH"
                fault! if ary_len(x) >= 0xFFFF
                ary_set(a, ary_len(x), a + 1)
                reg(a)
              end
      return set(step, a, value)
    end
    value = case name
            when "NOT" then bool(!truthy?(x))
            when "SLEEPMS", "SLEEP"
              # 時間はハードウェア (ボードエミュレーター) だけが持つ。値は待った量 (CRuby の sleep と同じく n)。
              # 仮想の時計は待った分だけ進む
              fault! unless int?(y) && signed(y[1]) >= 0
              @slept += y[1] * (name == "SLEEP" ? 1_000_000 : 1000)
              y
            else
              fault! unless int?(x)
              return float_arith(step, a, "FMOD", signed(x[1]).to_f, fval(y)) if name == "MOD" && y && float?(y)
              core_error!(FpgaIsa::CERR_TYPE, y, x) unless y.nil? || int?(y)
              sx = signed(x[1])
              sy = y && signed(y[1])
              case name
              when "MOD"
                core_error!(FpgaIsa::CERR_ZERODIV) if sy.zero?
                int(sx % sy) # Ruby の % は floor 側に丸めた余り
              when "NEG" then int(-sx)
              when "SHL" then shift_left(sx, sy)
              when "SHR" then shift_left(sx, -sy)
              when "AND" then int(sx & sy)
              when "OR" then int(sx | sy)
              when "XOR" then int(sx ^ sy)
              when "INV" then int(~sx)
              when "ABS" then int(sx.abs)
              when "ZERO" then bool(sx.zero?)
              when "EVEN" then bool(sx.even?)
              when "ODD" then bool(sx.odd?)
              else fault!
              end
            end
    set(step, a, value)
  end

  # == : Integer 同士は値、配列同士はエラー (中身の比較はしない)、それ以外は型と値 (参照は同じものか)
  # ヒープのオブジェクトでない値同士の == (型が同じで、整数・シンボル・クラスは値も)
  def equal?(x, y)
    x[0] == y[0] && ([FpgaIsa::TAG_INT, FpgaIsa::TAG_SYM, FpgaIsa::TAG_CLASS].include?(x[0]) || ref?(x) ? x[1] == y[1] : true)
  end

  # 整数同士なら計算し、そうでなければ同名のメソッドを送る (その時は飛び先を返す)。
  # == はどちらもヒープのオブジェクトでなければ値を比べ、そうでなければ == を送る
  def binop(step, pc, name, a)
    x = reg(a)
    y = reg(a + 1)
    if name == "EQ"
      return send_op(step, pc, a, "==", 1) if ref?(x) || ref?(y)
      set(step, a, bool(equal?(x, y)))
      return nil
    end
    ops = { "ADD" => "+", "SUB" => "-", "MUL" => "*", "DIV" => "/", "LT" => "<", "LE" => "<=", "GT" => ">", "GE" => ">=" }
    return send_op(step, pc, a, ops[name], 1) unless int?(x) && int?(y)
    sx = signed(x[1])
    sy = signed(y[1])
    value = case name
            when "ADD" then int(sx + sy)
            when "SUB" then int(sx - sy)
            when "MUL" then int(sx * sy)
            when "DIV"
              core_error!(FpgaIsa::CERR_ZERODIV) if sy.zero?
              int(sx.div(sy)) # Ruby の / は floor 側に丸める。INT_MIN / -1 は折り返して INT_MIN
            when "LT"  then bool(sx < sy)
            when "LE"  then bool(sx <= sy)
            when "GT"  then bool(sx > sy)
            when "GE"  then bool(sx >= sy)
            end
    set(step, a, value)
    nil
  end
end
