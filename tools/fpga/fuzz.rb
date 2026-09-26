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
  PROLOGUE = 16
  STOPPERS = %w[STOP RETURN RETNIL ENTER BREAK RETURN_BLK].freeze

  def program(rng, len: 40)
    words = []
    12.times { |r| words << prologue_load(rng, r) }
    words << encode(FpgaIsa.op("SETCONST"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETCONST"), 2, 1, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 10, 0, 3)                                 # R10 = [R0, R1, R2]
    words << encode(FpgaIsa.op("BLOCK"), 11, PROLOGUE + rng.rand(len - PROLOGUE), block_c(rng)) # R11 = Proc
    ops = FpgaIsa::SUPPORTED.map { |n| FpgaIsa.op(n) }
    # 配列と Proc の命令は多めに (GC まで届くように)
    ops += %w[ARRAY ARRAY2 GETIDX SETIDX BLOCK BLKCALL SEND AREF].map { |n| FpgaIsa.op(n) }
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

  def block_c(rng)
    lam = rng.rand(4).zero? ? 0x80 : 0
    rng.rand(3) | lam | ((1 + rng.rand(6)) << 8) # 引数の数 | lambda | nregs << 8
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
      # sleep_ms / sleep は引数が大きいとシミュレーションが終わらないので除く (コーパスと mrb_core_tb で見る)
      b = rng.rand(FpgaIsa::BUILTINS.size + 1)
      b = FpgaIsa.builtin("size", 0) if FpgaIsa::SELF_BUILTINS.include?((FpgaIsa::BUILTINS[b] || [])[0])
      c = rng.rand(100) < 85 ? (FpgaIsa::BUILTINS[b] ? FpgaIsa::BUILTINS[b][1] : 0) : rng.rand(3)
    when "SSEND", "SSEND0"
      b = PROLOGUE + rng.rand(len - PROLOGUE)
      argc = op.name == "SSEND" ? rng.rand(3) : 0
      c = ((1 + rng.rand(8)) << 8) | argc
    when "ENTER" then a = rng.rand(3)
    when "GETUPVAR", "SETUPVAR", "BLKPUSH" then b = rng.rand(12); c = rng.rand(4)
    when "BREAK" then b = PROLOGUE + rng.rand(len - PROLOGUE); c = rng.rand(2)
    when "RETURN_BLK" then c = rng.rand(3)
    when "ARRAY" then b = rng.rand(5)
    when "ARRAY2" then b = rng.rand(12); c = rng.rand(5)
    when "GETIDX0" then b = small.call
    when "BLOCK" then b = PROLOGUE + rng.rand(len - PROLOGUE); c = block_c(rng)
    when "BLKCALL" then b = rng.rand(3)
    when "AREF" then b = small.call; c = rng.rand(4)
    when "LOADSYM" then b = rng.rand(8)
    end
    encode(op, a, b, c)
  end

  # ヒープを突く program。R0..R7 は小さい整数、R8..R11 は配列や Proc。安全な形の断片 (配列を作る、push、
  # 代入、添字で読む、pop、include?、Proc を呼ぶ) を並べて先頭へ戻るループにし、GC を何度も起こす。
  # R12..R15 は断片の作業用。ブロックの本体は ROM の後ろ (外側の変数を読み書きし、配列も作る)
  HEAP_STEPS = 3000

  def heap_program(rng, body: 30)
    ints = (0..7).to_a
    arrs = (8..10).to_a
    words = []
    8.times { |r| words << encode(FpgaIsa.op("LOADI8"), r, rng.rand(20), 0) }
    words << encode(FpgaIsa.op("ARRAY2"), 8, 0, 3)
    words << encode(FpgaIsa.op("ARRAY2"), 9, 0, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 10, 8, 1)
    words << encode(FpgaIsa.op("SETCONST"), 8, 0, 0)
    block_at = nil # BLOCK の先頭 pc は最後に決める
    words << :block
    top = words.size
    wrong_argc = rng.rand(20).zero? # lambda なら数違いはエラー
    body.times do
      pick = rng.rand(11)
      case pick
      when 0 # 配列を作って R8..R10 のどれかに (前のはゴミになる)
        words << encode(FpgaIsa.op("ARRAY2"), arrs.sample(random: rng), ints.sample(random: rng), rng.rand(5))
      when 1 # push
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("MOVE"), 13, (ints + arrs).sample(random: rng), 0)
        words << encode(FpgaIsa.op("SEND"), 12, FpgaIsa.builtin(rng.rand(2).zero? ? "push" : "<<", 1), 1)
      when 2 # a[i] = v (伸ばすこともある)
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("LOADI8"), 13, rng.rand(24), 0)
        words << encode(FpgaIsa.op("MOVE"), 14, (ints + arrs).sample(random: rng), 0)
        words << encode(FpgaIsa.op("SETIDX"), 12, 0, 0)
      when 3 # v = a[i]
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("LOADI16"), 13, (rng.rand(20) - 6) & 0xFFFF, 0)
        words << encode(FpgaIsa.op("GETIDX"), 12, 0, 0)
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0) # 要素は nil や配列のこともあるので作業用へ
      when 4 # pop / size / first / last / include?
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        name = %w[pop size first last empty?].sample(random: rng)
        words << encode(FpgaIsa.op("SEND0"), 12, FpgaIsa.builtin(name, 0), 0)
        words << encode(FpgaIsa.op("MOVE"), name == "size" ? ints.sample(random: rng) : 15, 12, 0)
      when 5
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << encode(FpgaIsa.op("SEND"), 12, FpgaIsa.builtin("include?", 1), 1)
      when 6 # Proc を呼ぶ
        words << encode(FpgaIsa.op("MOVE"), 12, 11, 0)
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << encode(FpgaIsa.op("BLKCALL"), 12, 1, 0)
      when 7 # 定数に配列を置く / 読む
        words << encode(FpgaIsa.op(rng.rand(2).zero? ? "SETCONST" : "GETCONST"), arrs.sample(random: rng), 0, 0)
      when 9 # メソッドが作った Proc を、メソッドから戻った後で呼ぶ (退避済みの env)。定数 1 にも置いて GC を越えさせる
        words << :call_maker
        words << encode(FpgaIsa.op("SETCONST"), 12, 1, 0) if rng.rand(2).zero?
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << encode(FpgaIsa.op("BLKCALL"), 12, wrong_argc ? 2 : 1, 0)
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 10 # 多重代入 (AREF)
        words << encode(FpgaIsa.op("AREF"), 15, arrs.sample(random: rng), rng.rand(4))
      else # 整数の計算
        words << encode(FpgaIsa.op("ADDI"), ints.sample(random: rng), rng.rand(4), 0)
      end
    end
    words << encode(FpgaIsa.op("JMP"), 0, top, 0)
    # ブロック: 外側の R0..R7 を読み書きし、配列を作って返す
    block_at = words.size
    words << encode(FpgaIsa.op("GETUPVAR"), 2, rng.rand(8), 1)
    words << encode(FpgaIsa.op("ADD"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETUPVAR"), 1, rng.rand(8), 1)
    words << encode(FpgaIsa.op("ARRAY2"), 2, 1, 2)
    words << encode(FpgaIsa.op("RETURN"), 2, 0, 0)
    # Proc を作って返すメソッド (nregs 4)。その Proc は env が退避された後に外側の R0..R3 を読み書きし、
    # ときどき外 (R4 以降、エラー) に触り、return / break で戻る (メソッドはもう無いので lambda でなければエラー)
    maker_at = words.size
    words << encode(FpgaIsa.op("LOADI8"), 1, rng.rand(50), 0)
    words << encode(FpgaIsa.op("LOADI8"), 2, rng.rand(50), 0)
    words << :inner
    words << encode(FpgaIsa.op("RETURN"), 3, 0, 0)
    inner_at = words.size
    outer = -> { rng.rand(40).zero? ? 4 + rng.rand(3) : rng.rand(3) } # R3 は Proc 自身
    words << encode(FpgaIsa.op("GETUPVAR"), 2, outer.call, 1)
    words << encode(FpgaIsa.op("ADD"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETUPVAR"), 1, outer.call, 1)
    words << encode(FpgaIsa.op("ARRAY2"), 2, 1, 1)
    last = rng.rand(24)
    words << encode(FpgaIsa.op(last.zero? ? "RETURN_BLK" : last == 1 ? "BREAK" : "RETURN"), 1, 0, last < 2 ? 1 : 0)
    lam = rng.rand(3).zero? ? 0x80 : 0
    words.map do |w|
      case w
      when :block then encode(FpgaIsa.op("BLOCK"), 11, block_at, 1 | (4 << 8))
      when :call_maker then encode(FpgaIsa.op("SSEND0"), 12, maker_at, 4 << 8)
      when :inner then encode(FpgaIsa.op("BLOCK"), 3, inner_at, 1 | lam | (4 << 8))
      else w
      end
    end
  end

  def hex(words)
    words.map { |w| format("%012x\n", w) }.join
  end

  # 入力の刺激もランダムに (button 用)
  def stim(rng)
    Array.new(rng.rand(4)) { [rng.rand(40), 2, rng.rand(3) - 1] }
  end
end
