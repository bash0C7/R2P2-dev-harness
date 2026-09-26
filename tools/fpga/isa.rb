# mruby の命令表 (RITE0400) と、FPGA の CPU コアが実行する部分集合。
#
# 番号と operand 形式は mruby/mruby の include/mruby/ops.h の並び順そのもの。
# ハードウェアも mruby の opcode 番号をそのまま使うので、トレースの op は
# `mrbc -v` の出力と同じ名前に引ける。ops.h との一致は isa_test.rb が確かめる
# (vendor/picoruby がある時だけ)。
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

  Op = Struct.new(:name, :num, :fmt) do
    # opcode の1バイトを除いた operand のバイト数
    def operand_bytes
      FORMAT_BYTES.fetch(fmt)
    end
  end

  FORMAT_BYTES = { "Z" => 0, "B" => 1, "BB" => 2, "BBB" => 3, "BS" => 3, "BSS" => 5, "S" => 2, "W" => 3 }.freeze

  OPS = ALL.each_with_index.map { |(name, fmt), i| Op.new(name, i, fmt) }.freeze
  BY_NAME = OPS.to_h { |op| [op.name, op] }.freeze

  # CPU コアが実行する命令 (docs/spec.md §10「対応命令」)。fpga/corpus/*.rb に出る命令と、
  # 同じ族で回路がほぼ増えないもの (LOADI_n 全部、比較4種、ADDI/SUBI、JMPIF/JMPNIL) まで。
  SUPPORTED = %w[
    NOP MOVE LOADI8 LOADINEG LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5
    LOADI_6 LOADI_7 LOADI16 LOADI32 LOADNIL LOADTRUE LOADFALSE GETGV SETGV
    JMP JMPIF JMPNOT JMPNIL ADD ADDI SUB SUBI ADDILV SUBILV EQ LT LE GT GE
    RETURN RETNIL STOP
  ].freeze

  JUMPS = %w[JMP JMPIF JMPNOT JMPNIL].freeze

  # レジスタの値の型タグ (2bit)。偽は nil と false だけ。
  TAG_NIL   = 0
  TAG_FALSE = 1
  TAG_TRUE  = 2
  TAG_INT   = 3

  INT_BITS = 32

  module_function

  def op(name_or_num)
    name_or_num.is_a?(Integer) ? OPS.fetch(name_or_num) : BY_NAME.fetch(name_or_num)
  end

  def supported?(name)
    SUPPORTED.include?(name)
  end
end
