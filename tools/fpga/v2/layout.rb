# v2 のコアの記憶の配置 (設計 §2・§3・§14)。起動の像の道具 (image.rb)、参照 (ref.rb)、firmware (fpga/firmware/、
# 定数は gen_layout が書く 00_layout.rb) が同じ値を使う。
#
# 記憶はバイト単位の番地 (32bit)。語は 4 バイト big endian (.mrb と同じ向き)。
module FpgaV2
  module Layout
    # C: none (D02)
    WORD = 4

    # 値 (レジスタ 1 本、mruby の MRB_NO_BOXING の mrb_value) の tag。レジスタは {tag 4bit, 値 64bit}
    # C: include/mruby/boxing_no.h mrb_value (D01)
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
    # C: src/load.c MRB_DUMP_NULL_SYM_LEN
    NULL_SYM = 0xFFFF_FFFF

    # 記憶の中の値: 16 バイト = {tag (u32), 0 (u32), 上位 32bit, 下位 32bit}
    # C: include/mruby/boxing_no.h mrb_value (D01)
    VALUE = 16

    # オブジェクトの見出し (mruby の MRB_OBJECT_HEADER、object.h): +0 クラスの番地、+4 {flags 20bit << 12 | frozen << 11 | gc の色 3bit << 8 | tt}
    # C: include/mruby/object.h MRB_OBJECT_HEADER
    H_CLASS = 0
    H_FLAGS = 4
    HEADER = 8
    # 固定長の枠 (mruby の RVALUE に当たる)。見出し + 56 バイト
    # C: src/gc.c RVALUE (D03)
    SLOT = 64

    # tt (mruby の enum mrb_vtype と同じ番号、value.h の MRB_VTYPE_FOREACH の並び)
    # C: include/mruby/value.h MRB_VTYPE_FOREACH
    TT = {
      FALSE: 0, TRUE: 1, SYMBOL: 2, UNDEF: 3, FREE: 4, FLOAT: 5, INTEGER: 6, CPTR: 7, OBJECT: 8, CLASS: 9, MODULE: 10,
      SCLASS: 11, HASH: 12, CDATA: 13, EXCEPTION: 14, ICLASS: 15, PROC: 16, ARRAY: 17, STRING: 18, RANGE: 19, ENV: 20,
      FIBER: 21, STRUCT: 22, ISTRUCT: 23, BREAK: 24
    }.freeze

    # 型ごとの欄 (枠の中のバイト位置)。ポインタは 4 バイト、値は VALUE
    # RClass (class.h): 親、実行時のメソッド表、ROM のメソッド表 (build の時)、定数と iv の表、名前 (シンボル)、入れ物 (outer)
    # C: include/mruby/class.h RClass (D04)
    C_SUPER = 8
    C_MT    = 12
    C_ROM   = 16
    C_IV    = 60 # 定数とクラスのインスタンス変数 (mruby と同じく iv の表に)。IV と同じ位置
    C_NAME  = 24
    C_OUTER = 28 # 入れ物のクラス。特異クラスでは付いているオブジェクト (mruby の __attached__)
    # RObject: iv の表
    # C: include/mruby/object.h RObject (D06)
    O_IV = 60
    # iv の表 (インスタンス変数と定数) は、iv を持てる型 (mruby の obj_iv_p: OBJECT CLASS MODULE SCLASS HASH CDATA EXCEPTION) の枠の
    # この位置 (最後の語)。表: 見出し {数, 容量, 行の並び} と、行 {シンボル (u32), 値 (VALUE)} (20 バイト)。空きはシンボル MT_EMPTY
    # C: src/variable.c iv_tbl (D06)
    IV = 60
    IV_ENTRY = 20
    # RString: 長さ (バイト)、容量、中身の番地
    # C: include/mruby/string.h RString (D04)
    S_LEN  = 8
    S_CAPA = 12
    S_PTR  = 16
    # RArray: 長さ、容量、中身 (VALUE の並び) の番地
    # C: include/mruby/array.h RArray (D04)
    A_LEN  = 8
    A_CAPA = 12
    A_PTR  = 16
    # C: src/array.c ARY_DEFAULT_LEN
    ARY_DEFAULT_LEN = 4
    # RRange (range.h、MRB_NO_BOXING なので MRB_RANGE_EMBED でない形): edges (beg と end の値 2 つの領域の番地)、excl。
    # 初期化の印は flags の bit 0 (RANGE_INITIALIZED_FLAG)
    # C: include/mruby/range.h RRange (D04)
    RG_EDGES = 8
    RG_EXCL = 12
    # C: include/mruby/range.h RANGE_INITIALIZED_FLAG
    RANGE_INITIALIZED_FLAG = 1
    # RHash (hash.h の MRB_32BIT の形): size、hsh (ar は hash_entry の並びの番地、ht は hash_table の番地)。iv の表は IV (D06)。
    # ar の ea_capa と ea_n_used、ht の ib_bit は見出しの flags (H_FLAGS_SHIFT から上) に置く (32bit の DEFINE_FLAG_ACCESSOR)
    # C: include/mruby/hash.h RHash (D04)
    HS_SIZE = 8
    HS_HSH = 12
    # hash_table (hash.c、MRB_32BIT): ea の番地、ea_capa、ea_n_used、ib (uint32_t の並び) の先頭
    # C: src/hash.c hash_table
    HT_EA = 0
    HT_EA_CAPA = 4
    HT_EA_N_USED = 8
    HT_IB = 12
    # hash_entry (hash.c): key と val の値 2 つ。消した行は key が undef
    # C: src/hash.c hash_entry
    HASH_ENTRY = 32
    HE_KEY = 0
    HE_VAL = 16
    # flags の bit (hash.h)。ar の ea_capa は bit 0〜4、ea_n_used は bit 5〜9、ht の ib_bit は bit 0〜4
    # C: include/mruby/hash.h MRB_HASH_AR_EA_CAPA_MASK
    MRB_HASH_AR_EA_CAPA_MASK = 31
    MRB_HASH_AR_EA_N_USED_SHIFT = 5
    MRB_HASH_AR_EA_N_USED_MASK = 992
    MRB_HASH_IB_BIT_MASK = 31
    MRB_HASH_DEFAULT = 1024
    MRB_HASH_PROC_DEFAULT = 2048
    MRB_HASH_HT = 4096
    # hash.c の大きさの定数 (IB_INIT_BIT は ib_upper_bound_for(16) <= AR_MAX_SIZE なので 5、EA_MAX_CAPA は IB_MAX_CAPA - 2)
    # C: src/hash.c AR_MAX_SIZE
    AR_MAX_SIZE = 16
    AR_DEFAULT_CAPA = 4
    IB_INIT_BIT = 5
    IB_TYPE_BIT = 32
    EA_N_RESERVED_INDICES = 2
    EA_MAX_INCREASE = 65_535
    EA_MAX_CAPA = 2_147_483_646
    # index_buckets_iter (hash.c): 各欄 4 バイト (h は RHash の番地)
    # C: src/hash.c index_buckets_iter
    IT_H = 0
    IT_BIT = 4
    IT_MASK = 8
    IT_INITIAL_POS = 12
    IT_POS = 16
    IT_ARY_INDEX = 20
    IT_EA_INDEX = 24
    IT_SHIFT1 = 28
    IT_SHIFT2 = 32
    IT_STEP = 36
    IT_SIZE = 40
    # struct h_check_modified (hash.c): flags、tbl、ht_ea_capa、ht_ea
    # C: src/hash.c h_check_modified
    HCM_FLAGS = 0
    HCM_TBL = 4
    HCM_EA_CAPA = 8
    HCM_EA = 12
    HCM_SIZE = 16
    # C: src/hash.c H_CHECK_MODIFIED_FLAGS_MASK
    H_CHECK_MODIFIED_FLAGS_MASK = 4127
    # 見出しの語の frozen の bit (MRB_OBJECT_HEADER の frozen:1、tt 8bit と gc の色 3bit の上)
    # C: include/mruby/object.h MRB_OBJECT_HEADER
    H_FROZEN = 2048
    # RProc (proc.h): irep の番地か primitive の番号、上の Proc、env、target_class、flags
    # C: include/mruby/proc.h RProc (D15)
    P_BODY   = 8
    P_UPPER  = 12
    P_ENV    = 16
    P_TCLASS = 20
    P_FLAGS  = 24
    PROC_IREP = 0 # flags の下位 2bit: 本体の種類
    PROC_PRIM = 1
    PROC_IVGET = 2 # attr_reader (本体はシンボル @x)
    PROC_IVSET = 3 # attr_writer
    # mruby の proc.h の flags を同じ値で (下位 2bit の種類 (D15) と重ならない)
    # C: include/mruby/proc.h MRB_PROC_STRICT
    PROC_STRICT = 256
    PROC_ORPHAN = 512
    PROC_ENVSET = 1024
    PROC_SCOPE  = 2048
    PROC_CREF   = 16_384
    PROC_METHOD_FLAGS = PROC_STRICT | PROC_SCOPE | PROC_CREF # vm.c の vm_define_method と mrb_method_proc_new

    # 命令の番号 (ops.h の OPCODE の並び。mrb_proc_arity が irep の最初の命令を見る)
    # C: include/mruby/ops.h OPCODE
    OP_ENTER = 57

    # REnv (proc.h): 見出し + stack (値の並びの番地) + cxt (mrb_context、0 は閉じた env) + mid。
    # 長さ (下 8bit) と blk の位置 (8〜13bit) は見出しの flags (H_FLAGS の 12bit から、MRB_ENV_LEN / MRB_ENV_BIDX)
    # C: include/mruby/proc.h REnv
    E_STACK = 8
    E_CXT   = 12
    E_MID   = 16
    H_FLAGS_SHIFT = 12
    # クラスの flags の下 5bit はインスタンスの tt (class.h の MRB_INSTANCE_TT_MASK)。見出しの語では H_FLAGS_SHIFT から
    # C: include/mruby/class.h MRB_INSTANCE_TT_MASK
    INSTANCE_TT_MASK = 0x1F
    # クラスの flags の印 (class.h)。見出しの語では H_FLAGS_SHIFT だけ上 (flags の bit 17 / 18 / 19 は語の bit 29 / 30 / 31)
    # C: include/mruby/class.h MRB_FL_CLASS_IS_INHERITED
    CLASS_IS_INHERITED = 1 << 29
    # C: include/mruby/class.h MRB_FL_CLASS_IS_ORIGIN
    CLASS_IS_ORIGIN = 1 << 30
    # C: include/mruby/class.h MRB_FL_CLASS_IS_PREPENDED
    CLASS_IS_PREPENDED = 1 << 31
    # C: include/mruby/class.h MRB_FL_CLASS_EQ_DEFINED
    CLASS_EQ_DEFINED = 1 << 28
    # bop の bit (mruby.h の MRB_BOP_*): Integer の + - * / == < <= > >= が 0〜8、Float が 9〜17、Symbol#== が 18、nil / true / false の == が 19
    # C: include/mruby.h MRB_BOP_COUNT
    BOP_COUNT = 9
    # C: include/mruby.h MRB_BOP_SYMBOL_EQ_SLOT
    BOP_SYMBOL_EQ_SLOT = 18
    # C: include/mruby.h MRB_BOP_NIL_TRUE_FALSE_EQ
    BOP_NIL_TRUE_FALSE_EQ = 1 << 19

    # RException (error.h): 見出し + mesg (RString か 0) + backtrace (0 か RArray)。iv の表は IV (D06)
    # C: include/mruby/error.h RException (D04)
    EX_MESG = 8
    EX_BACKTRACE = 12
    # RBreak (error.h): 見出し + ci_break_index (cibase からの ci の数) + val。tag は flags の 8〜10bit (vm.c の RBREAK_TAG_BIT_OFF)
    # C: include/mruby/error.h RBreak (D04)
    BRK_INDEX = 8
    BRK_VAL = 16
    # C: src/vm.c RBREAK_TAG_BIT_OFF
    RBREAK_TAG_BIT_OFF = 8
    RBREAK_TAG_BREAK = 0
    RBREAK_TAG_JUMP = 1
    RBREAK_TAG_STOP = 2
    # catch handler の行 (irep.h の mrb_irep_catch_handler): type (1)、begin / end / target (big endian の 4 バイト)。type は 0 rescue、1 ensure
    # C: include/mruby/irep.h mrb_irep_catch_handler
    CATCH_ENTRY = 13
    MRB_CATCH_RESCUE = 0
    MRB_CATCH_ENSURE = 1

    # メソッド表 (ROM も実行時も同じ形): 見出し {数 (u32), 容量 (u32), 行の並びの番地 (u32)} と、行 {シンボル (u32), 値 (u32)} × 容量。
    # 開番地法 (位置 = シンボル & (容量 - 1) から1行ずつ)、空きはシンボル 0xFFFFFFFF。見出しと行を分けるのは、表を大きくしても
    # 見出しの番地が変わらないため (module の iclass が同じ見出しを指す。mruby の iclass->mt = m->mt と同じ)。
    # 値はメソッド表では Proc の番地、特権の primitive の表では primitive の番号
    # C: src/class.c mrb_mt_tbl (D05)
    MT_COUNT = 0
    MT_CAPA  = 4
    MT_ROWS  = 8
    MT_HEAD  = 12
    MT_ENTRY = 8
    MT_EMPTY = 0xFFFF_FFFF
    # メソッド表の値の下位 2bit は可視性 (Proc の番地は 8 の倍数)。mruby の MRB_METHOD_VISIBILITY
    # C: src/class.c MRB_METHOD_PRIVATE_FL (D05)
    VIS_PUBLIC = 0
    VIS_PRIVATE = 1
    VIS_PROTECTED = 2
    VIS_MASK = 3

    # irep (mruby の mrb_irep、irep.h)。記憶の中の構造体 (オブジェクトではない)
    # C: include/mruby/irep.h mrb_irep
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
    # C: include/mruby.h mrb_state (D18)
    CORE_ARRAY  = 8
    CORE_STRING = 9
    CORE_PROC   = 10
    CORE_HASH   = 11
    CORE_RANGE  = 12
    CORE_OBJECT = 13
    CORE_CLASS  = 14
    CORE_MODULE = 15
    CORE_COUNT  = 16

    # 番地 0 は mrb_state (mruby.h の struct mrb_state の欄を同じ順で。使う欄だけ、jmp は無い)。語の番号 (番地 = 4 × 番号)。
    # gc_* は mrb_state.gc (gc.h の struct mrb_gc) の欄。symtbl / symcapa / symidx はシンボル表 (D07: FNV の開番地法、行 8 バイト {名前の番地, 長さ})
    # C: include/mruby.h mrb_state
    IMG = {
      c: 0, root_c: 1, globals: 2, exc: 3, top_self: 4,
      object_class: 5, class_class: 6, module_class: 7, proc_class: 8, string_class: 9, array_class: 10, hash_class: 11,
      range_class: 12, float_class: 13, integer_class: 14, true_class: 15, false_class: 16, nil_class: 17, symbol_class: 18,
      kernel_module: 19, gc_arena: 20, gc_arena_capa: 21, gc_arena_idx: 22, gc_live: 23, gc_debt: 24,
      symidx: 25, symtbl: 26, symcapa: 27, eException_class: 28, eStandardError_class: 29, nomem_err: 30, stack_err: 31,
      arena_err: 32,
      # 像だけの欄 (D18): 印、ヒープの範囲、組み込みのクラスの表、firmware の入口、programs、primitive の表、mrblib の .mrb (0 は無し)
      magic: 33, version: 34, heap_start: 35, heap_end: 36, core_classes: 37, fw_entry: 38, programs: 39, nprograms: 40,
      prims: 41, mrblib: 42,
      # mrb_state.nan_serial (NaN の通し番号、uint64_t を上と下の 2 語で。C の並びでは gc の後、D18)
      nan_serial: 43, nan_serial_lo: 44,
      # mrb_state.bop_redefined (演算子の再定義の印の bit) と bop_builtin (起動の時のメソッド表の値の並び、19 語の番地。0 は起動の途中)
      bop_redefined: 45, bop_builtin: 46
    }.freeze
    IMG_WORDS = 48
    # C: none (D18)
    IMG_MAGIC = "FPV2"
    IMG_VERSION = 2

    # mrb_context (mruby.h の struct mrb_context)。バイトの位置
    # C: include/mruby.h mrb_context
    CTX_PREV   = 0
    CTX_STBASE = 4
    CTX_STEND  = 8
    CTX_CI     = 12
    CTX_CIBASE = 16
    CTX_CIEND  = 20
    CTX_SVARS  = 24
    CTX_STATUS = 28
    CTX_FIB    = 32
    CTX_SIZE   = 36

    # mrb_callinfo (mruby.h)。バイトの位置、番地は 32bit。n は下 4bit (15 は 15 以上、D12)、kw は bit 4
    # vis は mruby の bit (下 2bit が可視性、bit 3 が module_function、internal.h の MRB_CI_VISIBILITY / MRB_CI_MODFUNC_P)
    # pc は iseq の中の絶対の番地、stack は窓の先頭の値の番地、u は target_class か REnv (計画 S4-1)
    # C: include/mruby.h mrb_callinfo
    CI_N     = 0
    CI_CCI   = 1
    CI_VIS   = 2
    CI_MID   = 4
    CI_PROC  = 8
    CI_BLK   = 12
    CI_STACK = 16
    CI_PC    = 20
    CI_U     = 24
    # cci の値 (vm.c の CINFO_*)
    # C: src/vm.c CINFO_DIRECT
    CINFO_NONE   = 0
    CINFO_DIRECT = 2
    CI_MODFUNC_BIT = 8
    # C: include/mruby/internal.h MRB_CI_SET_VISIBILITY_BREAK
    CI_VISIBILITY_BREAK_BIT = 4
    # C: include/mruby/internal.h MRB_CI_SET_GIVEN_CLASS
    CI_GIVEN_CLASS_BIT = 16
    # mrb_callinfo の後ろの延長 (D11 罠の続き、D12 引数の数)。CI_CONT は続きの種類 (CONT_*)
    # C: none (D11)
    CI_CONT   = 3
    CI_ARGC   = 28
    CI_CA     = 32
    CI_CN     = 36
    CI_CSYM   = 40
    CI_CRET   = 44
    CI_CDST   = 48
    CI_CFCALL = 52
    CI_SIZE   = 64
    # C: src/vm.c MRB_CALL_LEVEL_MAX
    MRB_CALL_LEVEL_MAX = 512
    CONT_NONE    = 0 # 普通の戻り (呼んだ側の R[a] か dst へ)
    CONT_ADVANCE = 1 # 罠の命令を終えて次へ
    CONT_SEND    = 2 # 探索の罠の続き (見つかれば呼ぶ、無ければ method_missing)
    CONT_VALUE   = 3 # 罠の結果を R[a] へ (attr)
    CONT_BOOT    = 4 # 起動 (戻ったら止まる)
    CONT_RUN     = 5 # __fpga_run (結果を dst へ)
    CONT_KWSEND  = 6 # キーワード引数を Hash にまとめた罠の続き (まとめた後の SEND)
    CONT_BLKSEND = 7 # ブロックを Proc にした罠の続き (vm.c の ensure_block の後の SEND)
    # ci->kw (mrb_callinfo の kw の bit、CI_N の bit 4)
    CI_KW_BIT = 16
  end
end
