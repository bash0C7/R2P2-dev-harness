# CPU コアの参照インタプリタ (ゴールデンモデル)。
#
# ROM (rom.rb の 48bit 語) を1命令ずつ実行し、ハードウェアのシミュレーション
# (fpga/sim/mrb_run_tb.sv) と同じ書式のトレースを出す。命令の意味の正本は
# mruby/mruby の src/vm.c。ここに書くのは FPGA 版として決めた意味 (docs/spec.md §10):
#   - 整数は 32bit で折り返す (mruby の Integer の範囲外は仕様外)
#   - 整数以外への算術・大小比較は「エラー停止」(mruby ならメソッド探索に行く)
#   - RETURN / RETNIL / STOP で停止
#
# トレース (1行1イベント、数値は10進、値は16進8桁):
#   X <step> <pc> <op>          命令を実行した
#   W <step> <reg> <tag> <val>  レジスタに書いた
#   O <step> <port> <tag> <val> I/O ポートに書いた (SETGV)
#   H <step> <pc>               停止命令で止まった
#   E <step> <pc> <op>          エラーで止まった
#   L <step>                    命令数の上限に達した
# 合否は O 行と最後の1行 (H/E/L) で見る。X/W 行はずれた場所を探すため。
require_relative "converter"

class FpgaRefVm
  MASK = (1 << FpgaIsa::INT_BITS) - 1
  NIL = [FpgaIsa::TAG_NIL, 0].freeze

  # stim: [[step, port, value], ...]。step 以降の命令から port の入力が value になる。
  def initialize(words, nregs: 16, stim: [])
    @rom = words
    @regs = Array.new(nregs) { NIL }
    @io = Array.new(FpgaIoMap::NPORTS) { NIL }
    @stim = stim.sort_by(&:first)
    @trace = []
  end

  attr_reader :trace, :regs, :io

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
    v &= MASK
    [FpgaIsa::TAG_INT, v]
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

  def set(step, reg, value)
    return :error if reg >= @regs.size
    @regs[reg] = value
    @trace << format("W %d %d %d %08x", step, reg, value[0], value[1])
    nil
  end

  def reg(r)
    @regs[r] || :bad
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
    return :error if a >= @regs.size && !%w[NOP JMP RETNIL STOP].include?(name)

    err = case name
          when "NOP" then nil
          when "MOVE"
            return :error if b >= @regs.size
            set(step, a, reg(b))
          when "LOADI8"   then set(step, a, int(b & 0xFF))
          when "LOADINEG" then set(step, a, int(-(b & 0xFF)))
          when "LOADI__1" then set(step, a, int(-1))
          when /\ALOADI_(\d)\z/ then set(step, a, int(Regexp.last_match(1).to_i))
          when "LOADI16"  then set(step, a, int(sext16(b)))
          when "LOADI32"  then set(step, a, int((b << 16) | c))
          when "LOADNIL"  then set(step, a, NIL)
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
          when "JMP" then return b
          when "JMPIF"  then return(truthy?(reg(a)) ? b : nxt)
          when "JMPNOT" then return(truthy?(reg(a)) ? nxt : b)
          when "JMPNIL" then return(reg(a)[0] == FpgaIsa::TAG_NIL ? b : nxt)
          when "ADD", "SUB", "EQ", "LT", "LE", "GT", "GE"
            return :error if a + 1 >= @regs.size
            binop(step, name, a)
          when "ADDI", "SUBI"
            return :error unless int?(reg(a))
            d = b & 0xFF
            set(step, a, int(name == "ADDI" ? reg(a)[1] + d : reg(a)[1] - d))
          when "ADDILV", "SUBILV"
            return :error unless int?(reg(a))
            d = c & 0xFF
            set(step, a, int(name == "ADDILV" ? reg(a)[1] + d : reg(a)[1] - d))
          when "RETURN", "RETNIL", "STOP" then return :halt
          end
    err == :error ? :error : nxt
  end

  def binop(step, name, a)
    x = reg(a)
    y = reg(a + 1)
    if name == "EQ"
      eq = int?(x) && int?(y) ? x[1] == y[1] : x[0] == y[0] && !int?(x)
      return set(step, a, bool(eq))
    end
    return :error unless int?(x) && int?(y)
    sx = signed(x[1])
    sy = signed(y[1])
    value = case name
            when "ADD" then int(sx + sy)
            when "SUB" then int(sx - sy)
            when "LT"  then bool(sx < sy)
            when "LE"  then bool(sx <= sy)
            when "GT"  then bool(sx > sy)
            when "GE"  then bool(sx >= sy)
            end
    set(step, a, value)
  end
end
