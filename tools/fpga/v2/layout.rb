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
    # 名前の無いシンボル (mruby の 0、.mrb の MRB_DUMP_NULL_SYM_LEN)
    NULL_SYM = 0xFFFF_FFFF

    # 記憶の中の値: 16 バイト = {tag (u32), 0 (u32), 上位 32bit, 下位 32bit}
    VALUE = 16

    # オブジェクトの見出し (mruby の MRB_OBJECT_HEADER、object.h): +0 クラスの番地、+4 {flags 20bit << 12 | frozen << 11 | gc の色 3bit << 8 | tt}
    H_CLASS = 0
    H_FLAGS = 4
    HEADER = 8
    # 固定長の枠 (mruby の RVALUE に当たる)。見出し + 56 バイト
    SLOT = 64

    # ヒープのブロック (V2c): 確保したものは全部 {見出し 8 バイト, 中身}。番地は中身の先頭 (オブジェクトなら RBasic)。
    # 見出し: +0 大きさ (見出しを含むバイト数、8 の倍数)、+4 flags。ヒープは先頭から大きさでたどれる
    BLOCK = 8
    B_SIZE = 0
    B_FLAGS = 4
    BF_MARK = 1 # GC の印 (sweep で消す)
    BF_FREE = 2 # 空きのブロック (中身の先頭の語は次の空きのブロックの番地)
    BF_PERM = 4 # 解放しない (読み込んだ irep、実行時のシンボルの名前。mruby もシンボルと irep は GC で消さない)
    # 作りかけのオブジェクトを守る (mruby の GC の arena、MRB_GC_ARENA_SIZE): 回路は最近確保したブロックをこの数だけ覚え、GC は根にする
    ARENA = 100
    # 起動の像の中のオブジェクト (コアのクラスなど。ブロックではない) の GC の色は見出しの gc の色 (H_FLAGS の bit 8)。
    # 印の値は GC ごとに反す (像の gc_color、mruby の白と黒の入れ替えと同じ考え)
    GC_COLOR_BIT = 1 << 8

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
    C_IV    = 60 # 定数とクラスのインスタンス変数 (mruby と同じく iv の表に)。IV と同じ位置
    C_NAME  = 24
    C_OUTER = 28 # 入れ物のクラス。特異クラスでは付いているオブジェクト (mruby の __attached__)
    # RObject: iv の表
    O_IV = 60
    # iv の表 (インスタンス変数と定数) は、iv を持てる型 (mruby の obj_iv_p: OBJECT CLASS MODULE SCLASS HASH CDATA EXCEPTION) の枠の
    # この位置 (最後の語)。表: 見出し {数, 容量, 行の並び} と、行 {シンボル (u32), 値 (VALUE)} (20 バイト)。空きはシンボル MT_EMPTY
    IV = 60
    IV_ENTRY = 20
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
    PROC_IVGET = 2 # attr_reader (本体はシンボル @x)
    PROC_IVSET = 3 # attr_writer
    PROC_LAMBDA = 1 << 2 # mruby の MRB_PROC_STRICT

    # メソッド表 (ROM も実行時も同じ形): 見出し {数 (u32), 容量 (u32), 行の並びの番地 (u32)} と、行 {シンボル (u32), 値 (u32)} × 容量。
    # 開番地法 (位置 = シンボル & (容量 - 1) から1行ずつ)、空きはシンボル 0xFFFFFFFF。見出しと行を分けるのは、表を大きくしても
    # 見出しの番地が変わらないため (module の iclass が同じ見出しを指す。mruby の iclass->mt = m->mt と同じ)。
    # 値はメソッド表では Proc の番地、特権の primitive の表では primitive の番号
    MT_COUNT = 0
    MT_CAPA  = 4
    MT_ROWS  = 8
    MT_HEAD  = 12
    MT_ENTRY = 8
    MT_EMPTY = 0xFFFF_FFFF
    # メソッド表の値の下位 2bit は可視性 (Proc の番地は 8 の倍数)。mruby の MRB_METHOD_VISIBILITY
    VIS_PUBLIC = 0
    VIS_PRIVATE = 1
    VIS_PROTECTED = 2
    VIS_MASK = 3

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

    # 組み込みのクラスの表 (像の core_classes): 0〜7 は即値の tag のクラス、その後は回路が作るオブジェクトのクラス
    CORE_ARRAY  = 8
    CORE_STRING = 9
    CORE_PROC   = 10
    CORE_HASH   = 11
    CORE_RANGE  = 12
    CORE_OBJECT = 13
    CORE_CLASS  = 14
    CORE_MODULE = 15
    CORE_COUNT  = 16

    # 起動の像の見出し (番地 0)
    IMG_MAGIC = "FPV2"
    IMG_VERSION = 1
    # 見出しの語 (番地 = 4 × 番号)
    IMG = {
      magic: 0, version: 1, heap_start: 2, heap_end: 3, sym_table: 4, sym_capa: 5, sym_count: 6,
      core_classes: 7, main_obj: 8, fw_entry: 9, programs: 10, nprograms: 11, stack: 12, stack_end: 13, prims: 14, ci: 15,
      free_list: 16, gc_color: 17, roots: 18, nroots: 19, mark_stack: 20, mark_stack_end: 21
    }.freeze
    IMG_WORDS = 24
  end
end
