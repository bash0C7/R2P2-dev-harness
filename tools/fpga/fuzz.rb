# 参照インタプリタ (ref_vm.rb) と CPU コアのシミュレーションの差分ファズ。
#
# 対応命令からランダムに ROM を組み (エラーになる operand もわざと混ぜる)、両方で走らせて
# トレースを1行残らず比べる (I/O だけでなく X/W 行も)。コーパスの Ruby プログラムでは通らない
# 組み合わせ (0 で割る、範囲外のレジスタ、深い再帰、未定義の定数、引数の数違い、壊れたメソッド表) を突くため。
# rake fpga:fuzz[count,seed] と rake fpga:test (少数) が使う。
require_relative "converter"

module FpgaFuzz
  module_function

  # 1本の ROM (48bit 語の配列) を作る。pc 0 は TABLE、前置きで R0..R11 に値 (たいてい Integer) を入れ、
  # 定数を2つ決めてから、ランダムな命令を並べる。後ろにランダムなメソッド表を置く。
  # 前置きが無いと、ほとんどの program が nil への算術ですぐエラーになり浅い
  PROLOGUE = 17
  STOPPERS = %w[STOP RETURN RETNIL ENTER BREAK RETURN_BLK].freeze
  TABLE_LOG = 5
  NSYMS = 16 # 呼び出しに使うシンボルの番号は 0..15 (0..10 は演算の落ち先)
  # メソッド表に出すクラス (Class の即値はメタクラス、32 と 33 は「ユーザーのクラス」)
  CLASS_POOL = [FpgaIsa::CLS_NIL, FpgaIsa::CLS_FALSE, FpgaIsa::CLS_TRUE, FpgaIsa::CLS_INT, FpgaIsa::CLS_SYM,
                FpgaIsa::CLS_ARRAY, FpgaIsa::CLS_PROC, FpgaIsa::CLS_OBJECT, FpgaIsa::CLS_CLASS,
                32, 33, FpgaIsa::META | 32, FpgaIsa::META | 33].freeze
  # sleep_ms / sleep は引数が大きいとシミュレーションが終わらないので表に出さない (コーパスと mrb_core_tb で見る)
  FUZZ_PRIMS = (0...FpgaIsa::PRIMS.size).reject { |i| %w[SLEEPMS SLEEP].include?(FpgaIsa::PRIMS[i][3]) }.freeze

  def program(rng, len: 40)
    words = []
    words << encode(FpgaIsa.op("TABLE"), TABLE_LOG, 0, 0) # 表の位置は with_table が入れる
    12.times { |r| words << prologue_load(rng, r) }
    words << encode(FpgaIsa.op("SETCONST"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETCONST"), 2, 1, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 10, 0, 3)                                 # R10 = [R0, R1, R2]
    words << encode(FpgaIsa.op("BLOCK"), 11, PROLOGUE + rng.rand(len - PROLOGUE), block_c(rng)) # R11 = Proc
    ops = FpgaIsa::SUPPORTED.map { |n| FpgaIsa.op(n) }
    # 配列・Proc・呼び出しの命令は多めに (GC とメソッド探索まで届くように)
    ops += %w[ARRAY ARRAY2 GETIDX SETIDX BLOCK BLKCALL SEND SSEND SEND0 AREF CLASS].map { |n| FpgaIsa.op(n) }
    (len - PROLOGUE).times do |k|
      op = ops[rng.rand(ops.size)]
      # 止まる・戻る命令ばかりだと浅いので、3回に2回は引き直す
      op = ops[rng.rand(ops.size)] while STOPPERS.include?(op.name) && rng.rand(3) > 0
      words << word(rng, op, PROLOGUE + k, len)
    end
    with_table(words, random_table(rng, len))
  end

  # words[0] (TABLE) に表の先頭を入れ、表 (2**TABLE_LOG 語、変換器と同じハッシュと開番地法) を後ろに付ける
  def with_table(words, entries)
    base = words.size
    size = 1 << TABLE_LOG
    slots = Array.new(size, FpgaRom::PAD)
    entries.each do |cls, sym, tgt|
      h = FpgaIsa.table_hash(cls, sym, size - 1)
      tries = 0
      while slots[h] != FpgaRom::PAD && tries < size
        h = (h + 1) & (size - 1)
        tries += 1
      end
      slots[h] = (cls << 32) | (sym << 16) | tgt if slots[h] == FpgaRom::PAD # 満杯なら捨てる
    end
    words[0] |= base << 16
    words + slots
  end

  # ランダムなメソッド表: 親クラスへの輪 (たいてい Object へ) と、メソッド (pc) と primitive
  def random_table(rng, len)
    entries = []
    CLASS_POOL.each do |cls|
      next if cls == FpgaIsa::CLS_OBJECT || rng.rand(5).zero?
      sup = rng.rand(6).zero? ? CLASS_POOL.sample(random: rng) : FpgaIsa::CLS_OBJECT # たまに輪になる
      entries << [cls, FpgaIsa::SUPER_SYM, sup]
    end
    (6 + rng.rand(10)).times do
      cls = CLASS_POOL.sample(random: rng)
      sym = rng.rand(NSYMS)
      tgt = case rng.rand(20)
            when 0 then (FpgaIsa::TGT_IVAR << 14) | rng.rand(4)  # インスタンス変数 (attr_reader)。範囲外もある
            when 1 then (FpgaIsa::TGT_IVSET << 14) | rng.rand(4) # attr_writer
            when 2..8 then PROLOGUE + rng.rand(len - PROLOGUE)    # メソッド
            else (FpgaIsa::TGT_PRIM << 14) | FUZZ_PRIMS.sample(random: rng)
            end
      entries << [cls, sym, tgt]
    end
    # インスタンス変数の数と is_a? の行 (ユーザーのクラス)
    [32, 33].each do |cls|
      entries << [cls, FpgaIsa::NIVARS_SYM, rng.rand(4)] unless rng.rand(4).zero?
      entries << [FpgaIsa::ISA_BIT | cls, CLASS_POOL.sample(random: rng), 1] if rng.rand(2).zero?
    end
    entries
  end

  def prologue_load(rng, r)
    case rng.rand(20)
    when 0 then encode(FpgaIsa.op("LOADNIL"), r, 0, 0)
    when 1 then encode(FpgaIsa.op(rng.rand(2).zero? ? "LOADTRUE" : "LOADFALSE"), r, 0, 0)
    when 2 then encode(FpgaIsa.op("LOADSYM"), r, rng.rand(NSYMS), 0)
    when 3 then encode(FpgaIsa.op("CLASS"), r, [32, 33, FpgaIsa::CLS_INT].sample(random: rng), 0)
    else
      v = rng.rand(3).zero? ? rng.rand(1 << 32) : rng.rand(64) - 32 # 大きい値と小さい値
      v &= 0xFFFF_FFFF
      encode(FpgaIsa.op("LOADI32"), r, v >> 16, v & 0xFFFF)
    end
  end

  # BLOCK の c は lambda の印 (0x80) だけが意味を持つ。ほかの bit は捨てられることを確かめるために混ぜる
  def block_c(rng)
    lam = rng.rand(4).zero? ? 0x80 : 0
    rng.rand(3) | lam | ((1 + rng.rand(6)) << 8)
  end

  # 呼び出しの引数の数。たまに 15 (splat: R[a+1] が引数の配列)
  def argc(rng)
    rng.rand(8).zero? ? 15 : rng.rand(3)
  end

  def encode(op, a, b, c)
    (op.num << 40) | ((a & 0xFF) << 32) | ((b & 0xFFFF) << 16) | (c & 0xFFFF)
  end

  def word(rng, op, pc, len)
    small = -> { rng.rand(100) < 97 ? rng.rand(12) : rng.rand(256) }  # たまに範囲外のレジスタ
    code_pc = -> { PROLOGUE + rng.rand(len - PROLOGUE) }
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
    when "SEND", "SEND0", "SSEND", "SSEND0"
      b = rng.rand(NSYMS)
      n = op.name.end_with?("0") ? 0 : argc(rng)
      c = n | (rng.rand(4).zero? ? 0x80 : 0)
    when "ENTER" # 必須 a、nregs b、ときどき省略可能・残り・後ろの必須
      a = rng.rand(3)
      b = 1 + rng.rand(10)
      c = rng.rand(3).zero? ? rng.rand(3) | (rng.rand(2) << 5) | (rng.rand(3) << 6) : 0
    when "EXEC" then b = code_pc.call
    when "CLASS" then b = CLASS_POOL.sample(random: rng) & 0x7FFF
    when "TDEF", "SDEF" then b = rng.rand(NSYMS)
    when "TABLE" then a = rng.rand(16); b = rng.rand(0x10000) # 表を壊す (a > 13 はエラー)
    when "GETUPVAR", "SETUPVAR", "BLKPUSH" then b = rng.rand(12); c = rng.rand(4)
    when "BREAK" then b = code_pc.call; c = rng.rand(2)
    when "RETURN_BLK" then c = rng.rand(3)
    when "ARRAY" then b = rng.rand(5)
    when "ARRAY2" then b = rng.rand(12); c = rng.rand(5)
    when "GETIDX0" then b = small.call
    when "BLOCK" then b = code_pc.call; c = block_c(rng)
    when "BLKCALL" then b = argc(rng)
    when "AREF" then b = small.call; c = rng.rand(4)
    when "LOADSYM" then b = rng.rand(NSYMS)
    when "GETIV", "SETIV" then b = rng.rand(NSYMS)
    when "SUPER" then b = rng.rand(NSYMS); c = argc(rng) | 0x80
    when "ARYPUSH" then b = rng.rand(4)
    when "APOST" then b = rng.rand(3); c = rng.rand(3)
    when "ARGARY" then b = (rng.rand(3) << 11) | (rng.rand(2) << 10) | (rng.rand(2) << 5)
    end
    encode(op, a, b, c)
  end

  # ヒープを突く program。R0..R7 は小さい整数、R8..R11 は配列や Proc。安全な形の断片 (配列を作る、push、
  # 代入、添字で読む、pop、Proc を呼ぶ、演算の落ち先) を並べて先頭へ戻るループにし、GC を何度も起こす。
  # R12..R15 は断片の作業用。ブロックの本体とメソッドは ROM の後ろ。呼び出しはメソッド表を引く
  HEAP_STEPS = 3000
  # heap_program が使うシンボルの番号
  S = { push: 11, shl: 12, size: 13, pop: 14, first: 15, last: 16, empty: 17, aget: 18, aset: 19,
        maker: 20, call: 21, new: 22, ia: 23, ib: 24, ic: 25, get: 26, geta: 27, setb: 28, getb: 29,
        isa: 30, respond: 31, vargs: 32 }.freeze
  # heap_program のクラス: P (32、@a @b) と Q (33 < P、@c を足す)。オブジェクトは定数 2 に置く
  P_CLS = 32
  Q_CLS = 33

  def heap_program(rng, body: 30)
    ints = (0..7).to_a
    arrs = (8..10).to_a
    words = []
    words << encode(FpgaIsa.op("TABLE"), TABLE_LOG, 0, 0)
    8.times { |r| words << encode(FpgaIsa.op("LOADI8"), r, rng.rand(20), 0) }
    words << encode(FpgaIsa.op("ARRAY2"), 8, 0, 3)
    words << encode(FpgaIsa.op("ARRAY2"), 9, 0, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 10, 8, 1)
    words << encode(FpgaIsa.op("SETCONST"), 8, 0, 0)
    words << encode(FpgaIsa.op("CLASS"), 12, P_CLS, 0)
    words << encode(FpgaIsa.op("LOADI8"), 13, rng.rand(20), 0)
    words << encode(FpgaIsa.op("SEND"), 12, S[:new], 1)
    words << encode(FpgaIsa.op("SETCONST"), 12, 2, 0)
    words << :block
    top = words.size
    wrong_argc = rng.rand(20).zero? # lambda なら数違いはエラー
    body.times do
      pick = rng.rand(17)
      case pick
      when 0 # 配列を作って R8..R10 のどれかに (前のはゴミになる)
        words << encode(FpgaIsa.op("ARRAY2"), arrs.sample(random: rng), ints.sample(random: rng), rng.rand(5))
      when 1 # push / <<
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("MOVE"), 13, (ints + arrs).sample(random: rng), 0)
        words << encode(FpgaIsa.op("SEND"), 12, rng.rand(2).zero? ? S[:push] : S[:shl], 1)
      when 2 # a[i] = v (伸ばすこともある)。SETIDX か Array#[]=
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("LOADI8"), 13, rng.rand(24), 0)
        words << encode(FpgaIsa.op("MOVE"), 14, (ints + arrs).sample(random: rng), 0)
        words << (rng.rand(2).zero? ? encode(FpgaIsa.op("SETIDX"), 12, 0, 0) : encode(FpgaIsa.op("SEND"), 12, S[:aset], 2))
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 3 # v = a[i]
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("LOADI16"), 13, (rng.rand(20) - 6) & 0xFFFF, 0)
        words << (rng.rand(2).zero? ? encode(FpgaIsa.op("GETIDX"), 12, 0, 0) : encode(FpgaIsa.op("SEND"), 12, S[:aget], 1))
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0) # 要素は nil や配列のこともあるので作業用へ
      when 4 # pop / size / first / last / empty?
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        name = %i[pop size first last empty].sample(random: rng)
        words << encode(FpgaIsa.op("SEND0"), 12, S[name], 0)
        words << encode(FpgaIsa.op("MOVE"), name == :size ? ints.sample(random: rng) : 15, 12, 0)
      when 5 # 配列の == (Array#== が無いので Object#== = 同じものか)
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("MOVE"), 13, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("EQ"), 12, 0, 0)
      when 6 # Proc を呼ぶ (BLKCALL か Proc#call)
        words << encode(FpgaIsa.op("MOVE"), 12, 11, 0)
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << (rng.rand(2).zero? ? encode(FpgaIsa.op("BLKCALL"), 12, 1, 0) : encode(FpgaIsa.op("SEND"), 12, S[:call], 1))
      when 7 # 定数に配列を置く / 読む
        words << encode(FpgaIsa.op(rng.rand(2).zero? ? "SETCONST" : "GETCONST"), arrs.sample(random: rng), 0, 0)
      when 9 # メソッドが作った Proc を、メソッドから戻った後で呼ぶ (退避済みの env)。定数 1 にも置いて GC を越えさせる
        words << encode(FpgaIsa.op("SSEND0"), 12, S[:maker], 0)
        words << encode(FpgaIsa.op("SETCONST"), 12, 1, 0) if rng.rand(2).zero?
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << encode(FpgaIsa.op("BLKCALL"), 12, wrong_argc ? 2 : 1, 0)
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 8 # オブジェクト: attr で読む、super を通して読む、attr で書く、is_a?、respond_to?
        words << encode(FpgaIsa.op("GETCONST"), 12, 2, 0)
        case rng.rand(5)
        when 0, 1
          words << encode(FpgaIsa.op("SEND0"), 12, %i[geta getb get].sample(random: rng).then { |k| S[k] }, 0)
        when 2
          words << encode(FpgaIsa.op("MOVE"), 13, (ints + arrs).sample(random: rng), 0)
          words << encode(FpgaIsa.op("SEND"), 12, S[:setb], 1)
        when 3
          words << encode(FpgaIsa.op("CLASS"), 13, [P_CLS, Q_CLS, FpgaIsa::CLS_INT, FpgaIsa::CLS_OBJECT].sample(random: rng), 0)
          words << encode(FpgaIsa.op("SEND"), 12, S[:isa], 1)
        else
          words << encode(FpgaIsa.op("LOADSYM"), 13, rng.rand(32), 0)
          words << encode(FpgaIsa.op("SEND"), 12, S[:respond], 1)
        end
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 12 # オブジェクトを作る (P か Q)。前のはゴミになる
        words << encode(FpgaIsa.op("CLASS"), 12, rng.rand(2).zero? ? P_CLS : Q_CLS, 0)
        words << encode(FpgaIsa.op("MOVE"), 13, (ints + arrs).sample(random: rng), 0)
        words << encode(FpgaIsa.op("SEND"), 12, S[:new], 1)
        words << encode(FpgaIsa.op("SETCONST"), 12, 2, 0)
      when 14 # 引数の形のあるメソッド vargs(a, b = 7, *r, c) を、いろいろな数で (たまに splat、数が足りなければエラー)
        n = rng.rand(24).zero? ? 1 : [2, 2, 3, 3, 4, 15].sample(random: rng)
        if n == 15
          words << encode(FpgaIsa.op("MOVE"), 13, arrs.sample(random: rng), 0)
        else
          n.times { |k| words << encode(FpgaIsa.op("MOVE"), 13 + k, (ints + arrs).sample(random: rng), 0) if 13 + k < 16 }
          n = [n, 3].min
        end
        words << encode(FpgaIsa.op("SSEND"), 12, S[:vargs], n)
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 15 # 配列の展開: [*a, *x] / [*a, x] / _, *b, c = a。1つ伸びるか縮む結果は R8..R10 に戻して GC を越えさせる
        # (配列同士をつないだ結果を戻すと倍々に伸びてヒープが尽きるので、作業用へ)
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        back = arrs.sample(random: rng)
        case rng.rand(3)
        when 0
          y = (ints + arrs).sample(random: rng)
          words << encode(FpgaIsa.op("MOVE"), 13, y, 0)
          words << encode(FpgaIsa.op("ARYCAT"), 12, 0, 0)
          back = 15 if arrs.include?(y)
        when 1
          words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
          words << encode(FpgaIsa.op("ARYPUSH"), 12, 1, 0)
        else
          words << encode(FpgaIsa.op("APOST"), 12, rng.rand(3), rng.rand(3))
        end
        words << encode(FpgaIsa.op("MOVE"), back, 12, 0)
      when 16 # proc |a, b| に配列1つ (展開する)
        words << encode(FpgaIsa.op("BLOCK"), 12, 0, 0) # 先頭 pc は後で入れる
        words[-1] = :pair
        words << encode(FpgaIsa.op("MOVE"), 13, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("BLKCALL"), 12, 1, 0)
        words << encode(FpgaIsa.op("MOVE"), 15, 12, 0)
      when 10 # 多重代入 (AREF)
        words << encode(FpgaIsa.op("AREF"), 15, arrs.sample(random: rng), rng.rand(4))
      when 11 # 演算の落ち先: 配列 + 整数 は Array#+ (この表ではメソッド) を送る
        words << encode(FpgaIsa.op("MOVE"), 12, arrs.sample(random: rng), 0)
        words << encode(FpgaIsa.op("MOVE"), 13, ints.sample(random: rng), 0)
        words << encode(FpgaIsa.op("ADD"), 12, 0, 0)
        words << encode(FpgaIsa.op("MOVE"), ints.sample(random: rng), 12, 0)
      else # 整数の計算
        words << encode(FpgaIsa.op("ADDI"), ints.sample(random: rng), rng.rand(4), 0)
      end
    end
    words << encode(FpgaIsa.op("JMP"), 0, top, 0)
    # ブロック: 外側の R0..R7 を読み書きし、配列を作って返す
    block_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 1, 4, 0) # |x|
    words << encode(FpgaIsa.op("GETUPVAR"), 2, rng.rand(8), 1)
    words << encode(FpgaIsa.op("ADD"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETUPVAR"), 1, rng.rand(8), 1)
    words << encode(FpgaIsa.op("ARRAY2"), 2, 1, 2)
    words << encode(FpgaIsa.op("RETURN"), 2, 0, 0)
    # Proc を作って返すメソッド (nregs 4)。その Proc は env が退避された後に外側の R0..R3 を読み書きし、
    # ときどき外 (R4 以降、エラー) に触り、return / break で戻る (メソッドはもう無いので lambda でなければエラー)
    maker_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 0, 4, 0)
    words << encode(FpgaIsa.op("LOADI8"), 1, rng.rand(50), 0)
    words << encode(FpgaIsa.op("LOADI8"), 2, rng.rand(50), 0)
    words << :inner
    words << encode(FpgaIsa.op("RETURN"), 3, 0, 0)
    inner_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 1, 4, 0) # |x| (lambda なら数を調べる)
    outer = -> { rng.rand(40).zero? ? 4 + rng.rand(3) : rng.rand(3) } # R3 は Proc 自身
    words << encode(FpgaIsa.op("GETUPVAR"), 2, outer.call, 1)
    words << encode(FpgaIsa.op("ADD"), 1, 0, 0)
    words << encode(FpgaIsa.op("SETUPVAR"), 1, outer.call, 1)
    words << encode(FpgaIsa.op("ARRAY2"), 2, 1, 1)
    last = rng.rand(24)
    words << encode(FpgaIsa.op(last.zero? ? "RETURN_BLK" : last == 1 ? "BREAK" : "RETURN"), 1, 0, last < 2 ? 1 : 0)
    # Array#+: 引数をそのまま返す
    plus_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 1, 4, 0)
    words << encode(FpgaIsa.op("RETURN"), 1, 0, 0)
    # P#initialize(x): @a = x、@b = [x]。Q#initialize は P のもの。@c は nil のまま
    init_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 1, 4, 0)
    words << encode(FpgaIsa.op("SETIV"), 1, S[:ia], 0)
    words << encode(FpgaIsa.op("ARRAY2"), 3, 1, 1)
    words << encode(FpgaIsa.op("SETIV"), 3, S[:ib], 0)
    words << encode(FpgaIsa.op("RETNIL"), 0, 0, 0)
    # P#get は @a、Q#get は super (P#get) と @c を配列にして返す
    pget_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 0, 3, 0)
    words << encode(FpgaIsa.op("GETIV"), 1, S[:ia], 0)
    words << encode(FpgaIsa.op("RETURN"), 1, 0, 0)
    qget_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 0, 4, 0)
    words << encode(FpgaIsa.op("SUPER"), 1, S[:get], 0x80)
    words << encode(FpgaIsa.op("GETIV"), 2, S[:ic], 0)
    words << encode(FpgaIsa.op("ARRAY2"), 1, 1, 2)
    words << encode(FpgaIsa.op("RETURN"), 1, 0, 0)
    # vargs(a, b = 7, *r, c): [a, b, r, c] を返す
    vargs_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 1, 8, 1 | (1 << 5) | (1 << 6))
    words << encode(FpgaIsa.op("JMP"), 0, vargs_at + 3, 0)
    words << encode(FpgaIsa.op("JMP"), 0, vargs_at + 4, 0)
    words << encode(FpgaIsa.op("LOADI_7"), 2, 0, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 6, 1, 4)
    words << encode(FpgaIsa.op("RETURN"), 6, 0, 0)
    # proc { |a, b| [b, a] }
    pair_at = words.size
    words << encode(FpgaIsa.op("ENTER"), 2, 5, 0)
    words << encode(FpgaIsa.op("MOVE"), 4, 1, 0)
    words << encode(FpgaIsa.op("MOVE"), 3, 2, 0)
    words << encode(FpgaIsa.op("ARRAY2"), 3, 3, 2)
    words << encode(FpgaIsa.op("RETURN"), 3, 0, 0)
    lam = rng.rand(3).zero? ? 0x80 : 0
    words = words.map do |w|
      case w
      when :block then encode(FpgaIsa.op("BLOCK"), 11, block_at, 0)
      when :inner then encode(FpgaIsa.op("BLOCK"), 3, inner_at, lam)
      when :pair then encode(FpgaIsa.op("BLOCK"), 12, pair_at, 0)
      else w
      end
    end
    prim = ->(name) { (FpgaIsa::TGT_PRIM << 14) | FpgaIsa.prim(name) }
    ary = FpgaIsa::CLS_ARRAY
    entries = [
      [ary, S[:push], prim.("PUSH")], [ary, S[:shl], prim.("APUSH")], [ary, S[:size], prim.("SIZE")],
      [ary, S[:pop], prim.("POP")], [ary, S[:first], prim.("FIRST")], [ary, S[:last], prim.("LAST")],
      [ary, S[:empty], prim.("EMPTY")], [ary, S[:aget], prim.("AGET")], [ary, S[:aset], prim.("ASET")],
      [ary, FpgaIsa::OP_SYMS.index("+"), plus_at], [ary, FpgaIsa::SUPER_SYM, FpgaIsa::CLS_OBJECT],
      [FpgaIsa::CLS_OBJECT, FpgaIsa::OP_SYMS.index("=="), prim.("OEQ")],
      [FpgaIsa::CLS_INT, S[:maker], maker_at], [FpgaIsa::CLS_PROC, S[:call], prim.("CALL")],
      [FpgaIsa::CLS_INT, S[:vargs], vargs_at],
      [FpgaIsa::META | P_CLS, S[:new], prim.("NEW")], [FpgaIsa::META | Q_CLS, S[:new], prim.("NEW")],
      [P_CLS, FpgaIsa::SUPER_SYM, FpgaIsa::CLS_OBJECT], [Q_CLS, FpgaIsa::SUPER_SYM, P_CLS],
      [P_CLS, FpgaIsa::NIVARS_SYM, 2], [Q_CLS, FpgaIsa::NIVARS_SYM, 3],
      [P_CLS, S[:ia], (FpgaIsa::TGT_IVAR << 14) | 0], [P_CLS, S[:ib], (FpgaIsa::TGT_IVAR << 14) | 1],
      [Q_CLS, S[:ic], (FpgaIsa::TGT_IVAR << 14) | 2],
      [P_CLS, FpgaIsa::OP_SYMS.index("initialize"), init_at], [P_CLS, S[:get], pget_at], [Q_CLS, S[:get], qget_at],
      [P_CLS, S[:geta], (FpgaIsa::TGT_IVAR << 14) | 0], [P_CLS, S[:getb], (FpgaIsa::TGT_IVAR << 14) | 1],
      [P_CLS, S[:setb], (FpgaIsa::TGT_IVSET << 14) | 1],
      [FpgaIsa::CLS_OBJECT, S[:isa], prim.("ISA")], [FpgaIsa::CLS_OBJECT, S[:respond], prim.("RESPOND")],
      [FpgaIsa::ISA_BIT | P_CLS, P_CLS, 1], [FpgaIsa::ISA_BIT | Q_CLS, Q_CLS, 1], [FpgaIsa::ISA_BIT | Q_CLS, P_CLS, 1]
    ]
    with_table(words, entries)
  end

  def hex(words)
    words.map { |w| format("%012x\n", w) }.join
  end

  # 入力の刺激もランダムに (button 用)
  def stim(rng)
    Array.new(rng.rand(4)) { [rng.rand(40), 2, rng.rand(3) - 1] }
  end
end
