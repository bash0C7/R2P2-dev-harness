# v2 のコアの記憶の配置 (設計 §2・§3・§14)。起動の像の道具 (image.rb)、参照 (ref.rb)、firmware (fpga/firmware/、
# 定数は gen_layout が書く 00_layout.rb) が同じ値を使う。
#
# 記憶はバイト単位の番地 (32bit)。語は 4 バイト big endian (.mrb と同じ向き)。
module FpgaV2
  module Layout
    WORD = 4

    # 値 (レジスタ 1 本、mruby の MRB_NO_BOXING の mrb_value) の tag。レジスタは {tag 4bit, 値 64bit}
    TAG_NIL   = 0
    TAG_FALSE = 1
    TAG_TRUE  = 2
    TAG_INT   = 3 # 64bit の2の補数
    TAG_SYM   = 4 # シンボルの番号
    TAG_FLOAT = 5 # IEEE 754 double のビット
    TAG_UNDEF = 6 # mruby の MRB_TT_UNDEF (引数の既定値の印など)
    TAG_OBJ   = 7 # ヒープのオブジェクトの番地
    TAG_NAMES = %w[nil false true int sym float undef obj].freeze

    # 記憶の中の値: 16 バイト = {tag (u32), 0 (u32), 上位 32bit, 下位 32bit}
    VALUE = 16

    # オブジェクトの見出し (mruby の MRB_OBJECT_HEADER、object.h): +0 クラスの番地、+4 {flags 20bit << 12 | frozen << 11 | gc の色 3bit << 8 | tt}
    H_CLASS = 0
    H_FLAGS = 4
    HEADER = 8
    # 固定長の枠 (mruby の RVALUE に当たる)。見出し + 56 バイト
    SLOT = 64

    # tt (mruby の enum mrb_vtype と同じ番号、value.h の MRB_VTYPE_FOREACH の並び)
    TT = {
      FALSE: 0, TRUE: 1, SYMBOL: 2, UNDEF: 3, FREE: 4, FLOAT: 5, INTEGER: 6, CPTR: 7, OBJECT: 8, CLASS: 9, MODULE: 10,
      SCLASS: 11, HASH: 12, CDATA: 13, EXCEPTION: 14, ICLASS: 15, PROC: 16, ARRAY: 17, STRING: 18, RANGE: 19, ENV: 20
    }.freeze

    # 型ごとの欄 (枠の中のバイト位置)。ポインタは 4 バイト、値は VALUE
    # RClass (class.h): 親、実行時のメソッド表、ROM のメソッド表 (build の時)、定数と iv の表、名前 (シンボル)、入れ物 (outer)
    C_SUPER = 8
    C_MT    = 12
    C_ROM   = 16
    C_IV    = 20
    C_NAME  = 24
    C_OUTER = 28
    # RObject: iv の表
    O_IV = 8
    # RString: 長さ (バイト)、容量、中身の番地
    S_LEN  = 8
    S_CAPA = 12
    S_PTR  = 16
    # RArray: 長さ、容量、中身 (VALUE の並び) の番地
    A_LEN  = 8
    A_CAPA = 12
    A_PTR  = 16
    # RProc (proc.h): irep の番地か primitive の番号、上の Proc、env、target_class、flags
    P_BODY   = 8
    P_UPPER  = 12
    P_ENV    = 16
    P_TCLASS = 20
    P_FLAGS  = 24
    PROC_IREP = 0 # flags の下位 2bit: 本体の種類
    PROC_PRIM = 1
    PROC_LAMBDA = 1 << 2 # mruby の MRB_PROC_STRICT

    # メソッド表 (ROM も実行時も同じ形): {数 (u32), 容量 (u32), [シンボル (u32), Proc の番地 (u32)] × 容量}。開番地法、空きはシンボル 0xFFFFFFFF
    MT_COUNT = 0
    MT_CAPA  = 4
    MT_ENTRIES = 8
    MT_ENTRY = 8
    MT_EMPTY = 0xFFFF_FFFF

    # irep (mruby の mrb_irep、irep.h)。記憶の中の構造体 (オブジェクトではない)
    I_NLOCALS = 0  # u16 nlocals, u16 nregs
    I_NREGS   = 2
    I_ILEN    = 4  # iseq のバイト数
    I_ISEQ    = 8  # iseq の番地 (.mrb の中を指す)
    I_POOL    = 12 # pool (VALUE の並び。文字列は RString ではなく {長さ, 番地} の印を持つ、下の POOL_STR)
    I_PLEN    = 16
    I_SYMS    = 20 # シンボルの番号 (u32) の並び
    I_SLEN    = 24
    I_REPS    = 28 # 子 irep の番地 (u32) の並び
    I_RLEN    = 32
    I_CATCH   = 36 # catch handler の並び (.mrb の中を指す、13 バイトずつ)
    I_CLEN    = 40
    IREP = 44
    # pool の文字列: tag = TAG_UNDEF、上位 = 長さ、下位 = バイト列の番地 (STRING 命令が RString を作る)

    # 起動の像の見出し (番地 0)
    IMG_MAGIC = "FPV2"
    IMG_VERSION = 1
    # 見出しの語 (番地 = 4 × 番号)
    IMG = {
      magic: 0, version: 1, heap_start: 2, heap_end: 3, sym_table: 4, sym_capa: 5, sym_count: 6,
      core_classes: 7, main_obj: 8, fw_entry: 9, programs: 10, nprograms: 11, stack: 12, stack_end: 13
    }.freeze
    IMG_WORDS = 16
  end
end
