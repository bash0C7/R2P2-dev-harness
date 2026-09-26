# mruby の命令表 (RITE0400) と、FPGA の CPU コアが実行する部分集合。
#
# 番号と operand 形式は mruby/mruby の include/mruby/ops.h の並び順そのもの。
# ハードウェアも mruby の opcode 番号をそのまま使うので、トレースの op は
# `mrbc -v` の出力と同じ名前に引ける。ops.h との一致は isa_test.rb が確かめる
# (vendor/picoruby がある時だけ)。
#
# 変換器 (mrb2rom.rb) の一部として PicoRuby でも走るので、PicoRuby と CRuby の共通部分だけで書く
# (Struct・require・Enumerator の連鎖・sort_by・sum・正規表現のキャプチャは使わない。docs/spec.md §10)。
module FpgaIsa
  # ops.h の OPCODE(name, fmt) を上から順に。
  ALL = %w[
    NOP:Z MOVE:BB LOADL:BB LOADI8:BB LOADINEG:BB LOADI__1:B LOADI_0:B LOADI_1:B
    LOADI_2:B LOADI_3:B LOADI_4:B LOADI_5:B LOADI_6:B LOADI_7:B LOADI16:BS LOADI32:BSS
    LOADSYM:BB LOADNIL:B LOADSELF:B LOADTRUE:B LOADFALSE:B GETGV:BB SETGV:BB GETSV:BB
    SETSV:BB GETIV:BB SETIV:BB GETCV:BB SETCV:BB GETCONST:BB SETCONST:BB GETMCNST:BB
    SETMCNST:BB GETUPVAR:BBB SETUPVAR:BBB GETIDX:B GETIDX0:BB SETIDX:B JMP:S JMPIF:BS
    JMPNOT:BS JMPNIL:BS JMPUW:S EXCEPT:B RESCUE:BB RAISEIF:B MATCHERR:B SSEND:BBB
    SSEND0:BB SSENDB:BBB SEND:BBB SEND0:BB SENDB:BBB CALL:Z BLKCALL:BB SUPER:BB
    ARGARY:BS ENTER:W KEY_P:BB KEYEND:Z KARG:BB RETURN:B RETURN_BLK:B RETSELF:Z
    RETNIL:Z RETTRUE:Z RETFALSE:Z BREAK:B BLKPUSH:BS ADD:B ADDI:BB SUB:B
    SUBI:BB ADDILV:BBB SUBILV:BBB MUL:B DIV:B EQ:B LT:B LE:B
    GT:B GE:B ARRAY:BB ARRAY2:BBB ARYCAT:B ARYPUSH:BB ARYSPLAT:B AREF:BBB
    ASET:BBB APOST:BBB INTERN:B SYMBOL:BB STRING:BB STRCAT:B HASH:BB HASHADD:BB
    HASHCAT:B LAMBDA:BB BLOCK:BB METHOD:BB RANGE_INC:B RANGE_EXC:B OCLASS:B CLASS:BB
    MODULE:BB EXEC:BB DEF:BB TDEF:BBB SDEF:BBB ALIAS:BB UNDEF:B SCLASS:B
    TCLASS:B DEBUG:BBB ERR:B EXT1:Z EXT2:Z EXT3:Z STOP:Z
  ].map { |e| e.split(":") }.freeze

  # opcode の1バイトを除いた operand のバイト数
  FORMAT_BYTES = { "Z" => 0, "B" => 1, "BB" => 2, "BBB" => 3, "BS" => 3, "BSS" => 5, "S" => 2, "W" => 3 }.freeze

  class Op
    attr_reader :name, :num, :fmt

    def initialize(name, num, fmt)
      @name = name
      @num = num
      @fmt = fmt
    end

    def operand_bytes
      FORMAT_BYTES[fmt]
    end
  end

  OPS = []
  ALL.each_with_index { |(name, fmt), i| OPS << Op.new(name, i, fmt) }
  OPS.freeze

  BY_NAME = {}
  OPS.each { |o| BY_NAME[o.name] = o }
  BY_NAME.freeze

  # CPU コアが実行する命令 (docs/spec.md §10「対応命令」)。fpga/corpus/*.rb に出る命令と、
  # 同じ族で回路がほぼ増えないもの (LOADI_n 全部、比較4種、ADDI/SUBI、JMPIF/JMPNIL) まで。
  # メソッド (TDEF/SSEND/SSEND0/ENTER) は変換時に呼び出し先を静的に解決する。SEND/SEND0 は下の BUILTINS だけ。
  SUPPORTED = %w[
    NOP MOVE LOADI8 LOADINEG LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5
    LOADI_6 LOADI_7 LOADI16 LOADI32 LOADNIL LOADTRUE LOADFALSE GETGV SETGV
    JMP JMPIF JMPNOT JMPNIL ADD ADDI SUB SUBI ADDILV SUBILV EQ LT LE GT GE
    RETURN RETNIL STOP
    TDEF SSEND SSEND0 ENTER SEND SEND0 MUL DIV GETCONST SETCONST
    GETUPVAR SETUPVAR BREAK
    ARRAY ARRAY2 GETIDX GETIDX0 SETIDX BLOCK BLKPUSH BLKCALL RETURN_BLK
  ].freeze

  # .mrb に出てよいが ROM には残らない命令。変換器がほかの命令に下げる (docs/spec.md §10「ブロック」)
  #   SENDB SSENDB  iterator (times / each / map ...) はループと BLKCALL に展開し、proc / lambda は Proc をそのまま返す。
  #                 def したメソッドへのブロック付き呼び出しは SSEND (ブロックを渡す印付き) にする
  LOWERED = %w[SENDB SSENDB].freeze

  # ブロックを取る組み込み: [名前, SENDB か SSENDB か, 引数の数]
  ITERATORS = [
    ["times", "SENDB", 0], ["upto", "SENDB", 1], ["downto", "SENDB", 1], ["loop", "SSENDB", 0],
    ["each", "SENDB", 0], ["each_with_index", "SENDB", 0], ["map", "SENDB", 0],
    ["proc", "SSENDB", 0], ["lambda", "SSENDB", 0]
  ].freeze

  JUMPS = %w[JMP JMPIF JMPNOT JMPNIL].freeze

  # レジスタの値の型タグ (3bit)。偽は nil と false だけ。ARRAY と PROC はヒープへの参照 (値 = 語アドレス)。
  # FWD と HDR はヒープの中だけに出る (GC の転送先、オブジェクトの見出し)
  TAG_BITS  = 3
  TAG_NIL   = 0
  TAG_FALSE = 1
  TAG_TRUE  = 2
  TAG_INT   = 3
  TAG_ARRAY = 4
  TAG_PROC  = 5
  TAG_FWD   = 6
  TAG_HDR   = 7

  # ヒープのオブジェクトの種類 (見出しの値 = 種類 << 16 | 中身の語数)
  #   配列  [HDR(ARY,2)] [INT 長さ] [ARRAY → 中身]      中身 [HDR(DATA,容量)] [要素 ...]
  #   Proc  [HDR(PROC,3)] [INT 先頭 pc | 引数の数 << 16 | nregs << 24] [INT 作ったフレームの bp] [外側の Proc か nil]
  KIND_ARY  = 1
  KIND_DATA = 2
  KIND_PROC = 3
  # ヒープは HEAP_SIZE 語を半分ずつ使う (コピー GC)
  HEAP_SIZE = 2048

  INT_BITS = 32

  # SEND / SEND0 で呼べる組み込みメソッド: [名前, 引数の数]。番号は並び順で、ROM の b に入る。
  # 受け手は Integer (「!」と「!=」は何でも、size..include? と「<<」は Array でもよい)。それ以外の SEND は変換時に止める
  BUILTINS = [
    ["%", 1], ["!=", 1], ["-@", 0], ["<<", 1], [">>", 1], ["&", 1], ["|", 1], ["^", 1],
    ["~", 0], ["!", 0], ["abs", 0], ["zero?", 0], ["even?", 0], ["odd?", 0],
    ["size", 0], ["length", 0], ["empty?", 0], ["first", 0], ["last", 0], ["pop", 0], ["push", 1], ["include?", 1],
    ["sleep_ms", 1], ["sleep", 1]
  ].freeze

  # 受け手を書かずに呼ぶ (SSEND) 組み込み。変換器が SEND の組み込みに直す
  SELF_BUILTINS = %w[sleep_ms sleep].freeze

  # CPU コアの大きさ。レジスタファイル (全フレームで共有するレジスタ窓)、コールスタック、定数の数
  RF_SIZE     = 128
  STACK_DEPTH = 16
  NCONST      = 16

  def self.builtin(name, argc)
    BUILTINS.each_with_index { |(n, a), i| return i if n == name && a == argc }
    nil
  end

  def self.op(name_or_num)
    o = name_or_num.is_a?(Integer) ? OPS[name_or_num] : BY_NAME[name_or_num]
    raise ArgumentError, "unknown op #{name_or_num.inspect}" unless o
    o
  end

  # ROM に出て、コアと参照インタプリタが実行する命令か
  def self.supported?(name)
    SUPPORTED.include?(name)
  end

  # 変換器が受け付ける命令か (実行するもの + 下げるもの)
  def self.convertible?(name)
    SUPPORTED.include?(name) || LOWERED.include?(name)
  end

  def self.iterator(name, kind, argc)
    ITERATORS.each { |it| return it if it[0] == name && it[1] == kind && it[2] == argc }
    nil
  end
end
