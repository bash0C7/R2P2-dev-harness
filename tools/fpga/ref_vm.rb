# CPU コアの参照インタプリタ (ゴールデンモデル)。
#
# ROM (rom.rb の 48bit 語) を1命令ずつ実行し、ハードウェアのシミュレーション
# (fpga/sim/mrb_run_tb.sv) と同じ書式のトレースを出す。命令の意味の正本は
# mruby/mruby の src/vm.c。ここに書くのは FPGA 版として決めた意味 (docs/spec.md §10):
#   - 整数は 32bit で折り返す (mruby の Integer の範囲外は仕様外)
#   - 整数以外への算術・大小比較、0 での割り算は「エラー停止」(mruby ならメソッド探索や例外)
#   - メソッド呼び出しはレジスタ窓: 呼び出し先の R0 は呼び出し元の R[a]。レジスタファイルは全フレームで共有
#   - RETURN / RETNIL はフレームが無ければ停止、あれば呼び出し元へ戻る。STOP は停止
#
# トレース (1行1イベント、数値は10進、値は16進8桁):
#   X <step> <pc> <op>          命令を実行した
#   W <step> <reg> <tag> <val>  レジスタに書いた (reg はレジスタファイルでの番号 = フレームの底 + R の番号)
#   O <step> <port> <tag> <val> I/O ポートに書いた (SETGV)
#   H <step> <pc>               停止命令で止まった
#   E <step> <pc> <op>          エラーで止まった
#   L <step>                    命令数の上限に達した
# 合否は O 行と最後の1行 (H/E/L) で見る。X/W 行はずれた場所を探すため。
# SSEND の self の写しと呼び出し先のレジスタの nil 埋め、SETCONST はトレースに出さない (ハードウェアも出さない)。
require_relative "converter"
require_relative "compare"

class FpgaRefVm
  MASK = (1 << FpgaIsa::INT_BITS) - 1
  INT_MIN = -(1 << (FpgaIsa::INT_BITS - 1))
  NIL = [FpgaIsa::TAG_NIL, 0].freeze

  # stim: [[step, port, value], ...]。step 以降の命令から port の入力が value になる。
  def initialize(words, nregs: FpgaIsa::RF_SIZE, stim: [])
    @rom = words
    @regs = Array.new(nregs) { NIL }
    @io = Array.new(FpgaIoMap::NPORTS) { NIL }
    @consts = Array.new(FpgaIsa::NCONST)
    @stack = []
    @bp = 0
    @argc = 0
    # step の順、同じ step なら与えられた順 (後が勝つ)。テストベンチもこの順で適用する
    @stim = FpgaCompare.sort_stim(stim)
    @trace = []
  end

  attr_reader :trace, :regs, :io, :consts

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
      result = execute(step, pc, op, a, b, c)
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

  def truthy?(r)
    r[0] == FpgaIsa::TAG_TRUE || r[0] == FpgaIsa::TAG_INT
  end

  def bool(x)
    [x ? FpgaIsa::TAG_TRUE : FpgaIsa::TAG_FALSE, 0]
  end

  def ok?(r)
    @bp + r < @regs.size
  end

  def reg(r)
    @regs[@bp + r]
  end

  def set(step, r, value)
    @regs[@bp + r] = value
    @trace << format("W %d %d %d %08x", step, @bp + r, value[0], value[1])
    nil
  end

  def input(step, port)
    v = 0
    @stim.each { |s, p, val| v = val if p == port && s <= step }
    int(v)
  end

  def execute(step, pc, op, a, b, c)
    name = FpgaIsa::OPS[op]&.name
    return :error unless name && FpgaIsa.supported?(name)
    nxt = pc + 1
    return :error if !ok?(a) && !%w[NOP JMP RETNIL STOP].include?(name)

    err = case name
          when "NOP" then nil
          when "MOVE"
            return :error unless ok?(b)
            set(step, a, reg(b))
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
            return :error if port >= FpgaIoMap::NPORTS
            value = FpgaIoMap::IN_MASK[port] == 1 ? input(step, port) : @io[port]
            set(step, a, value)
          when "SETGV"
            port = b & 0xFF
            return :error if port >= FpgaIoMap::NPORTS
            @io[port] = reg(a)
            @trace << format("O %d %d %d %08x", step, port, @io[port][0], @io[port][1])
            nil
          when "GETCONST"
            return :error if b >= FpgaIsa::NCONST || @consts[b].nil?
            set(step, a, @consts[b])
          when "SETCONST"
            return :error if b >= FpgaIsa::NCONST
            @consts[b] = reg(a)
            nil
          when "JMP" then return b
          when "JMPIF"  then return(truthy?(reg(a)) ? b : nxt)
          when "JMPNOT" then return(truthy?(reg(a)) ? nxt : b)
          when "JMPNIL" then return(reg(a)[0] == FpgaIsa::TAG_NIL ? b : nxt)
          when "ADD", "SUB", "MUL", "DIV", "EQ", "LT", "LE", "GT", "GE"
            return :error unless ok?(a + 1)
            binop(step, name, a)
          when "ADDI", "SUBI"
            return :error unless int?(reg(a))
            d = b & 0xFF
            set(step, a, int(name == "ADDI" ? reg(a)[1] + d : reg(a)[1] - d))
          when "ADDILV", "SUBILV"
            return :error unless int?(reg(a))
            d = c & 0xFF
            set(step, a, int(name == "ADDILV" ? reg(a)[1] + d : reg(a)[1] - d))
          when "SEND", "SEND0"
            return :error if c == 1 && !ok?(a + 1)
            builtin(step, b, a, c)
          when "SSEND", "SSEND0" then return call(pc, a, b, c)
          when "ENTER" then return(@argc == a ? nxt : :error)
          when "RETURN", "RETNIL" then return ret(step, name == "RETURN" ? reg(a) : NIL)
          when "STOP" then return :halt
          end
    err == :error ? :error : nxt
  end

  # 呼び出し: 呼び出し先のフレームの底は bp + a。R0 に self を写し、引数より後ろを nil で埋める
  def call(pc, a, target, c)
    argc = c & 0xFF
    nregs = c >> 8
    new_bp = @bp + a
    return :error if new_bp + [nregs, argc + 1].max > @regs.size || @stack.size >= FpgaIsa::STACK_DEPTH
    @stack.push([pc + 1, @bp])
    @regs[new_bp] = @regs[@bp]
    ((argc + 1)...nregs).each { |i| @regs[new_bp + i] = NIL }
    @bp = new_bp
    @argc = argc
    target
  end

  # 戻り: 呼び出し先の R0 (= 呼び出し元の R[a]) に値を置いて戻る。フレームが無ければ停止
  def ret(step, value)
    return :halt if @stack.empty?
    @regs[@bp] = value
    @trace << format("W %d %d %d %08x", step, @bp, value[0], value[1])
    pc, @bp = @stack.pop
    pc
  end

  def shift_left(x, s)
    return int(0) if s >= FpgaIsa::INT_BITS
    return int(x < 0 ? -1 : 0) if s <= -FpgaIsa::INT_BITS
    s >= 0 ? int(x << s) : int(x >> -s)
  end

  def builtin(step, id, a, argc)
    name, want = FpgaIsa::BUILTINS[id]
    return :error unless name && want == argc
    x = reg(a)
    y = argc == 1 ? reg(a + 1) : nil
    value = case name
            when "!" then bool(!truthy?(x))
            when "!=" then bool(!equal?(x, y))
            else
              return :error unless int?(x) && (y.nil? || int?(y))
              sx = signed(x[1])
              sy = y && signed(y[1])
              case name
              when "%"
                return :error if sy.zero?
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
              end
            end
    set(step, a, value)
  end

  def equal?(x, y)
    int?(x) && int?(y) ? x[1] == y[1] : x[0] == y[0] && !int?(x)
  end

  def binop(step, name, a)
    x = reg(a)
    y = reg(a + 1)
    return set(step, a, bool(equal?(x, y))) if name == "EQ"
    return :error unless int?(x) && int?(y)
    sx = signed(x[1])
    sy = signed(y[1])
    value = case name
            when "ADD" then int(sx + sy)
            when "SUB" then int(sx - sy)
            when "MUL" then int(sx * sy)
            when "DIV"
              return :error if sy.zero?
              int(sx.div(sy)) # Ruby の / は floor 側に丸める。INT_MIN / -1 は折り返して INT_MIN
            when "LT"  then bool(sx < sy)
            when "LE"  then bool(sx <= sy)
            when "GT"  then bool(sx > sy)
            when "GE"  then bool(sx >= sy)
            end
    set(step, a, value)
  end
end
