# 参照インタプリタ (ref_vm.rb) と CPU コアのシミュレーションの差分ファズ。
#
# 対応命令からランダムに ROM を組み (エラーになる operand もわざと混ぜる)、両方で走らせて
# トレースを1行残らず比べる (I/O だけでなく X/W 行も)。コーパスの Ruby プログラムでは通らない
# 組み合わせ (0 で割る、範囲外のレジスタ、深い再帰、未定義の定数、引数の数違い) を突くため。
# rake fpga:fuzz[count,seed] と rake fpga:test (少数) が使う。
require_relative "converter"

module FpgaFuzz
  module_function

  # 1本の ROM (48bit 語の配列) を作る。前置きで R0..R11 に値 (たいてい Integer) を入れ、定数を2つ決めてから、
  # ランダムな命令を並べる。前置きが無いと、ほとんどの program が nil への算術ですぐエラーになり浅い
  PROLOGUE = 14
  STOPPERS = %w[STOP RETURN RETNIL ENTER].freeze

  def program(rng, len: 40)
    words = []
    12.times { |r| words << prologue_load(rng, r) }
    words << encode(FpgaIsa.op("SETCONST"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETCONST"), 2, 1, 0)
    ops = FpgaIsa::SUPPORTED.map { |n| FpgaIsa.op(n) }
    (len - PROLOGUE).times do |k|
      op = ops[rng.rand(ops.size)]
      # 止まる・戻る命令ばかりだと浅いので、3回に2回は引き直す
      op = ops[rng.rand(ops.size)] while STOPPERS.include?(op.name) && rng.rand(3) > 0
      words << word(rng, op, PROLOGUE + k, len)
    end
    words
  end

  def prologue_load(rng, r)
    case rng.rand(20)
    when 0 then encode(FpgaIsa.op("LOADNIL"), r, 0, 0)
    when 1 then encode(FpgaIsa.op(rng.rand(2).zero? ? "LOADTRUE" : "LOADFALSE"), r, 0, 0)
    else
      v = rng.rand(3).zero? ? rng.rand(1 << 32) : rng.rand(64) - 32 # 大きい値と小さい値
      v &= 0xFFFF_FFFF
      encode(FpgaIsa.op("LOADI32"), r, v >> 16, v & 0xFFFF)
    end
  end

  def encode(op, a, b, c)
    (op.num << 40) | ((a & 0xFF) << 32) | ((b & 0xFFFF) << 16) | (c & 0xFFFF)
  end

  def word(rng, op, pc, len)
    small = -> { rng.rand(100) < 97 ? rng.rand(12) : rng.rand(256) }  # たまに範囲外のレジスタ
    a = small.call
    b = 0
    c = 0
    case op.name
    when "MOVE" then b = small.call
    when "LOADI8", "LOADINEG", "ADDI", "SUBI" then b = rng.rand(256)
    when "LOADI16" then b = rng.rand(0x10000)
    when "LOADI32" then b = rng.rand(0x10000); c = rng.rand(0x10000)
    when "ADDILV", "SUBILV" then b = small.call; c = rng.rand(256)
    when "GETGV", "SETGV" then b = rng.rand(FpgaIoMap::NPORTS + 1)
    when "GETCONST", "SETCONST" then b = rng.rand(4) # 未定義の定数も出るように少ない番号で
    when "JMP", "JMPIF", "JMPNOT", "JMPNIL" then b = PROLOGUE + rng.rand(len - PROLOGUE + 1) # たまに ROM の外
    when "SEND", "SEND0"
      b = rng.rand(FpgaIsa::BUILTINS.size + 1)
      c = rng.rand(100) < 85 ? (FpgaIsa::BUILTINS[b] ? FpgaIsa::BUILTINS[b][1] : 0) : rng.rand(3)
    when "SSEND", "SSEND0"
      b = PROLOGUE + rng.rand(len - PROLOGUE)
      argc = op.name == "SSEND" ? rng.rand(3) : 0
      c = ((1 + rng.rand(8)) << 8) | argc
    when "ENTER" then a = rng.rand(3)
    end
    encode(op, a, b, c)
  end

  def hex(words)
    words.map { |w| format("%012x\n", w) }.join
  end

  # 入力の刺激もランダムに (button 用)
  def stim(rng)
    Array.new(rng.rand(4)) { [rng.rand(40), 2, rng.rand(3) - 1] }
  end
end
