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
  # FPGA だけの命令 (mruby の番号の外)。TABLE は ROM の先頭の語: a = メソッド表の大きさの log2、b = 表の先頭の語アドレス
# HTABLE は例外の表 (catch handler) の位置と数 (b = 先頭の語アドレス、c = 数)。表がある時だけ pc 1 に置く
EXTRA = [["TABLE", 0xF0, "BS"], ["HTABLE", 0xF1, "BS"]].freeze
  EXTRA.each { |name, num, fmt| OPS[num] = Op.new(name, num, fmt) }
  OPS.freeze

  BY_NAME = {}
  OPS.each { |o| BY_NAME[o.name] = o if o }
  BY_NAME.freeze

  # CPU コアが実行する命令 (docs/spec.md §10「対応命令」)。
  # SEND / SEND0 / SSEND / SSEND0 はメソッド表を引く動的な呼び出し (b = シンボルの番号、c = 引数の数 | ブロック << 7)。
  # CLASS は R[a] = クラス b の即値、EXEC は R[a] を self にしてクラスの本体 (pc b) を呼ぶ。TDEF / SDEF は R[a] = :名前
  SUPPORTED = %w[
    NOP MOVE LOADI8 LOADINEG LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5
    LOADI_6 LOADI_7 LOADI16 LOADI32 LOADNIL LOADTRUE LOADFALSE GETGV SETGV
    JMP JMPIF JMPNOT JMPNIL ADD ADDI SUB SUBI ADDILV SUBILV EQ LT LE GT GE
    RETURN RETNIL STOP
    TDEF SSEND SSEND0 ENTER SEND SEND0 MUL DIV GETCONST SETCONST
    GETUPVAR SETUPVAR BREAK
    ARRAY ARRAY2 GETIDX GETIDX0 SETIDX BLOCK BLKPUSH BLKCALL RETURN_BLK AREF LOADSYM
    CLASS EXEC SDEF TABLE GETIV SETIV SUPER
    ARYCAT ARYPUSH APOST ARGARY STRING
    HTABLE EXCEPT RESCUE RAISEIF JMPUW
  ].freeze

  # .mrb に出てよいが ROM には残らない命令。変換器がほかの命令にする (docs/spec.md §10)
  #   SENDB SSENDB  ブロックを渡す印 (c の 0x80) を付けた SEND / SSEND
  #   LAMBDA        -> (x) { } は lambda の印を付けた BLOCK
  #   MODULE        CLASS と同じ (モジュールもクラスの番号を持つ)
  #   LOADSELF      MOVE a, R0
  #   RETSELF       RETURN R0
  #   RETTRUE / RETFALSE  LOADTRUE / LOADFALSE R0 と RETURN R0 (戻り値は呼び出し先の R0 に入るので同じ)
  #   GETCV / SETCV クラス変数は定数と同じ番号 (GETCONST / SETCONST)
  #   GETMCNST / SETMCNST  A::X は変換時に解いて CLASS / GETCONST / SETCONST
  #   STRCAT        SEND a+1 :to_s と SEND a :<< (式展開は新しい STRING から始まるので R[a] を伸ばしてよい)
  #   LOADL         32bit に収まる整数は LOADI32
  #   HASH HASHADD HASHCAT RANGE_INC RANGE_EXC  プレリュードの Hash / Range を作るメソッドの呼び出し (ARRAY と SEND)
  #   KARG KEY_P KEYEND  キーワード引数の Hash (R[len+1]) のメソッドの呼び出し。キーワード付きの SEND も下げる (rom.rb の kw_lowered)
  LOWERED = %w[SENDB SSENDB LAMBDA MODULE LOADSELF RETSELF RETTRUE RETFALSE GETCV SETCV GETMCNST SETMCNST STRCAT LOADL HASH HASHADD HASHCAT RANGE_INC RANGE_EXC
                KARG KEY_P KEYEND].freeze

  # メソッド表 (ROM の後ろ、TABLE の b から 2**a 語)。1語 = {クラス 16bit, シンボル 16bit, 飛び先 16bit}。
  # 空きは全 bit 1。(クラス, SUPER_SYM) の飛び先は親クラスの番号。探す位置は table_hash から順に (開番地法)
  SUPER_SYM = 0xFFFF
  # (クラス, NIVARS_SYM) の飛び先はインスタンス変数の数 (new が使う。無ければ 0)
  NIVARS_SYM = 0xFFFE
  # (ISA_BIT | クラス, 祖先の番号) があれば is_a? が真 (親はたどらない)
  ISA_BIT = 0x4000
  # (クラス, NAME_SYM) の飛び先はクラスの名前のシンボルの番号 (Module#name)
  NAME_SYM = 0xFFFD
  # 飛び先の上位 2bit: 0 = メソッドの先頭 pc、1 = primitive の番号 (下の PRIMS)、
  # 2 = インスタンス変数の番号 (GETIV / SETIV、attr_reader)、3 = インスタンス変数の番号 (attr_writer: R[a+1] を書いて返す)
  TGT_PC    = 0
  TGT_PRIM  = 1
  TGT_IVAR  = 2
  TGT_IVSET = 3
  # 親クラスをたどる段数の上限 (ランダムな表で輪になっても止まるように)
  MAX_SUPER_DEPTH = 32

  # 演算の命令 (ADD、EQ、GETIDX ...) が整数や配列でない値に当たった時に送るメソッドの名前。シンボルの番号はこの順で 0 から
# initialize は new が送るメソッド、__core_error はコアの実行時エラーを例外にするプレリュードのメソッド (コアが番号を知っている)
OP_SYMS = %w[+ - * / == < <= > >= [] []= initialize __core_error].freeze
# コアの実行時エラーの種類 (Integer#__core_error の受け手)。例外の表があるプログラムでだけ、コアはエラーで止まらずに
# フレームの上 (fn、ENTER では nregs から) に [種類, 詳細1, 詳細2] を置いて __core_error を呼ぶ (プレリュードが例外を作って投げる)
CERR_ZERODIV  = 1 # 0 で割った
CERR_NOMETHOD = 2 # メソッドが無い (詳細: 名前のシンボル、受け手)
CERR_ARGNUM   = 3 # 引数の数が違う (詳細: 渡した数、要る数)
CERR_TYPE     = 4 # Integer の演算の引数が Integer でない (詳細: 引数)
CERR_COMPARE  = 5 # Integer の比較の引数が Integer でない (詳細: 引数)

  def self.table_hash(cls, sym, mask)
    (cls * 5 + sym) & mask
  end

  # 回路が持つメソッド (primitive): [クラス, 名前, 引数の数 (-1 は何個でも), 定数名]。番号は並び順
  PRIMS = [
    ["Integer", "+", 1, "IADD"], ["Integer", "-", 1, "ISUB"], ["Integer", "*", 1, "IMUL"], ["Integer", "/", 1, "IDIV"],
    ["Integer", "<", 1, "ILT"], ["Integer", "<=", 1, "ILE"], ["Integer", ">", 1, "IGT"], ["Integer", ">=", 1, "IGE"],
    ["Integer", "==", 1, "IEQ"],
    ["Integer", "%", 1, "MOD"], ["Integer", "-@", 0, "NEG"], ["Integer", "<<", 1, "SHL"], ["Integer", ">>", 1, "SHR"],
    ["Integer", "&", 1, "AND"], ["Integer", "|", 1, "OR"], ["Integer", "^", 1, "XOR"], ["Integer", "~", 0, "INV"],
    ["Integer", "abs", 0, "ABS"], ["Integer", "zero?", 0, "ZERO"], ["Integer", "even?", 0, "EVEN"], ["Integer", "odd?", 0, "ODD"],
    ["Object", "!", 0, "NOT"], ["Object", "==", 1, "OEQ"], ["Object", "equal?", 1, "SAME"], ["Object", "class", 0, "CLASSOF"],
    ["Object", "sleep_ms", 1, "SLEEPMS"], ["Object", "sleep", 1, "SLEEP"], ["Object", "lambda", 0, "LAMBDA"],
    ["Object", "is_a?", 1, "ISA"], ["Object", "kind_of?", 1, "KINDOF"], ["Object", "respond_to?", 1, "RESPOND"],
    ["Class", "new", -1, "NEW"],
    ["Array", "size", 0, "SIZE"], ["Array", "length", 0, "LENGTH"], ["Array", "empty?", 0, "EMPTY"],
    ["Array", "first", 0, "FIRST"], ["Array", "last", 0, "LAST"], ["Array", "pop", 0, "POP"],
    ["Array", "push", 1, "PUSH"], ["Array", "<<", 1, "APUSH"], ["Array", "__aget", 1, "AGET"], ["Array", "[]=", 2, "ASET"],
    ["Proc", "call", -1, "CALL"],
    # String (Array と同じ形で、1語に1バイト)。ほかのメソッドはプレリュード。__ で始まるものはプレリュードの中身
    ["String", "bytesize", 0, "SBYTES"], ["String", "getbyte", 1, "SGETB"], ["String", "__aset", 2, "SASET"],
    ["String", "__push", 1, "SPUSH"], ["String", "__slice", 2, "SSLICE"], ["Symbol", "to_s", 0, "SYMSTR"],
    ["Module", "__name_sym", 0, "NAMESYM"],
    # 例外を投げる (Kernel#raise はプレリュード。引数は例外のオブジェクト)
    ["Object", "__raise", 1, "RAISE"]
  ].freeze

  def self.prim(const_name)
    PRIMS.each_with_index { |pr, i| return i if pr[3] == const_name }
    raise ArgumentError, "unknown primitive #{const_name}"
  end

  def self.class_id(name)
    CLASSES.each { |n, id| return id if n == name }
    nil
  end

  JUMPS = %w[JMP JMPIF JMPNOT JMPNIL].freeze

  # レジスタの値の型タグ (4bit)。偽は nil と false だけ。SYM はシンボルの番号、CLASS はクラスの番号の即値。
  # OBJ はヒープのオブジェクトへの参照 (値 = 語アドレス、クラスは見出しで分かる)。
  # FWD と HDR はヒープの中だけに出る (GC の転送先、オブジェクトの見出し)。9..15 は空き
  TAG_BITS  = 4
  TAG_NIL   = 0
  TAG_FALSE = 1
  TAG_TRUE  = 2
  TAG_INT   = 3
  TAG_SYM   = 4
  TAG_CLASS = 5
  TAG_OBJ   = 6
  TAG_FWD   = 7
  TAG_HDR   = 8
  TAGS = %w[NIL FALSE TRUE INT SYM CLASS OBJ FWD HDR].freeze

  # クラスの番号 (見出しの値 = クラス << 16 | 中身の語数)。組み込みは固定、ユーザーのクラスは FIRST_USER_CLASS から。
  # クラスメソッドは番号 | META のクラス (メタクラス) のメソッド。DATA と ENV はヒープの中だけの塊で、値にはならない
  #   Array [HDR(ARRAY,2)] [INT 長さ] [OBJ → 中身]      中身 [HDR(DATA,容量)] [要素 ...]
  #   Proc  [HDR(PROC,3)] [INT 先頭 pc | 引数の数 << 16 | lambda << 23 | nregs << 24] [env] [外側の Proc か nil]
  #   env   [HDR(ENV,1+n)] [INT フレームの bp (生きている間) か nil (退避済み)] [レジスタ × n]
  #         フレームの中で初めて Proc を作った時にでき、フレームから戻る時に n 本 (フレームの nregs) を写し取る
  CLASSES = [
    ["Object", 1], ["NilClass", 2], ["TrueClass", 3], ["FalseClass", 4], ["Integer", 5], ["Symbol", 6],
    ["Array", 7], ["Proc", 8], ["Class", 9], ["Module", 10], ["String", 11], ["Hash", 12], ["Range", 13],
    ["Float", 14], ["Exception", 15]
  ].freeze
  CLS_OBJECT = 1
  CLS_NIL    = 2
  CLS_TRUE   = 3
  CLS_FALSE  = 4
  CLS_INT    = 5
  CLS_SYM    = 6
  CLS_ARRAY  = 7
  CLS_PROC   = 8
  CLS_CLASS  = 9
  CLS_STRING = 11
  CLS_HASH   = 12
  CLS_RANGE  = 13
  CLS_EXC    = 15
  # new できてインスタンス変数を持てるクラス: Object、プレリュードが Ruby で書く組み込み (Hash / Range / Exception)、
  # プログラムのクラス (FIRST_USER_CLASS から CLS_DATA の前まで)
  def self.instantiable?(cls)
    cls == CLS_OBJECT || cls == CLS_HASH || cls == CLS_RANGE || cls == CLS_EXC || (cls >= FIRST_USER_CLASS && cls < CLS_DATA)
  end
  CLS_DATA   = 0x7FF0
CLS_ENV    = 0x7FF1
# 巻き戻しの途中 (ensure を走らせてから続ける return / break / JMPUW。mruby の RBreak) を表すヒープの塊。
#   [HDR(BRK,2)] [INT 種類 << 16 | 行き先] [値]。行き先は JUMP と BRK0 は pc、RET と BRK はフレームの底
CLS_BRK    = 0x7FF2
BRK_JUMP = 0 # JMPUW: 同じフレームの行き先 pc へ
BRK_RET  = 1 # 底が行き先のフレームから戻る (return、lambda の中の break、ブロックの中の return)
BRK_BRK  = 2 # 親の底が行き先のフレームを畳み、その呼び出しの結果にする (Proc を作ったフレームへの break)
BRK_BRK0 = 3 # 今のフレームを畳んで行き先 pc へ (iterator に直接渡したブロックの break)
# 例外の表 (HTABLE の b から c 語)。1語 = {種類 << 15 | 飛び先 (op と a の 16bit), begin (b), end (c)}。
# begin <= pc < end の命令が覆われる。種類は mruby と同じ 0 = rescue、1 = ensure。探す順に並べる (irep ごとに後ろから)
CATCH_RESCUE = 0
CATCH_ENSURE = 1
  FIRST_USER_CLASS = 32
  META = 0x8000
  # ヒープは HEAP_SIZE 語を半分ずつ使う (コピー GC)
  HEAP_SIZE = 2048

  INT_BITS = 32

  # CPU コアの大きさ。レジスタファイル (全フレームで共有するレジスタ窓)、コールスタック、定数の数、ROM の語数
  RF_SIZE     = 128
  STACK_DEPTH = 16
  NCONST      = 64
  PC_BITS     = 13

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

end
