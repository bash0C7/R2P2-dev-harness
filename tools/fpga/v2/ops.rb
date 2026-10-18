# mruby の命令表 (RITE0400、119 命令) と、可変長の命令のデコード。v2 のコアのデコーダの写し (設計 §3)。
#
# 表は mruby の include/mruby/ops.h をそのまま写した (番号は並びの順)。ops_test が vendor の ops.h と同じかを見る。
# 形式と EXT の意味は include/mruby/opcode.h の FETCH_* と vm.c の OP_EXT1〜3:
#   B = 1 バイト、S = 2 バイト (big endian)、W = 3 バイト。EXT1 は次の命令の a を S に、EXT2 は b を S に、EXT3 は a と b を S にする
module FpgaV2
  module Ops
    TABLE = [
      ["NOP",        "Z"   ], # no operation
      ["MOVE",       "BB"  ], # R[a] = R[b]
      ["LOADL",      "BB"  ], # R[a] = Pool[b]
      ["LOADI8",     "BB"  ], # R[a] = mrb_int(b)
      ["LOADINEG",   "BB"  ], # R[a] = mrb_int(-b)
      ["LOADI__1",   "B"   ], # R[a] = mrb_int(-1)
      ["LOADI_0",    "B"   ], # R[a] = mrb_int(0)
      ["LOADI_1",    "B"   ], # R[a] = mrb_int(1)
      ["LOADI_2",    "B"   ], # R[a] = mrb_int(2)
      ["LOADI_3",    "B"   ], # R[a] = mrb_int(3)
      ["LOADI_4",    "B"   ], # R[a] = mrb_int(4)
      ["LOADI_5",    "B"   ], # R[a] = mrb_int(5)
      ["LOADI_6",    "B"   ], # R[a] = mrb_int(6)
      ["LOADI_7",    "B"   ], # R[a] = mrb_int(7)
      ["LOADI16",    "BS"  ], # R[a] = mrb_int(b)
      ["LOADI32",    "BSS" ], # R[a] = mrb_int((b<<16)+c)
      ["LOADSYM",    "BB"  ], # R[a] = Syms[b]
      ["LOADNIL",    "B"   ], # R[a] = nil
      ["LOADSELF",   "B"   ], # R[a] = self
      ["LOADTRUE",   "B"   ], # R[a] = true
      ["LOADFALSE",  "B"   ], # R[a] = false
      ["GETGV",      "BB"  ], # R[a] = getglobal(Syms[b])
      ["SETGV",      "BB"  ], # setglobal(Syms[b], R[a])
      ["GETSV",      "BB"  ], # R[a] = Special[Syms[b]]
      ["SETSV",      "BB"  ], # Special[Syms[b]] = R[a]
      ["GETIV",      "BB"  ], # R[a] = ivget(Syms[b])
      ["SETIV",      "BB"  ], # ivset(Syms[b],R[a])
      ["GETCV",      "BB"  ], # R[a] = cvget(Syms[b])
      ["SETCV",      "BB"  ], # cvset(Syms[b],R[a])
      ["GETCONST",   "BB"  ], # R[a] = constget(Syms[b])
      ["SETCONST",   "BB"  ], # constset(Syms[b],R[a])
      ["GETMCNST",   "BB"  ], # R[a] = R[a]::Syms[b]
      ["SETMCNST",   "BB"  ], # R[a+1]::Syms[b] = R[a]
      ["GETUPVAR",   "BBB" ], # R[a] = uvget(b,c)
      ["SETUPVAR",   "BBB" ], # uvset(b,c,R[a])
      ["GETIDX",     "B"   ], # R[a] = R[a][R[a+1]]
      ["GETIDX0",    "BB"  ], # R[a] = R[b][0]; a+1 for method call
      ["SETIDX",     "B"   ], # R[a][R[a+1]] = R[a+2]
      ["JMP",        "S"   ], # pc+=a
      ["JMPIF",      "BS"  ], # if R[a] pc+=b
      ["JMPNOT",     "BS"  ], # if !R[a] pc+=b
      ["JMPNIL",     "BS"  ], # if R[a]==nil pc+=b
      ["JMPUW",      "S"   ], # unwind_and_jump_to(a)
      ["EXCEPT",     "B"   ], # R[a] = exc
      ["RESCUE",     "BB"  ], # R[b] = R[a].isa?(R[b])
      ["RAISEIF",    "B"   ], # raise(R[a]) if R[a]
      ["MATCHERR",   "B"   ], # raise NoMatchingPatternError unless R[a]
      ["SSEND",      "BBB" ], # R[a] = self.send(Syms[b],R[a+1]..,R[a+n+1]:R[a+n+2]..) (c=n|k<<4)
      ["SSEND0",     "BB"  ], # R[a] = self.send(Syms[b]) (no args)
      ["SSENDB",     "BBB" ], # R[a] = self.send(Syms[b],R[a+1]..,R[a+n+1]:R[a+n+2]..,&R[a+n+2k+1])
      ["SEND",       "BBB" ], # R[a] = R[a].send(Syms[b],R[a+1]..,R[a+n+1]:R[a+n+2]..) (c=n|k<<4)
      ["SEND0",      "BB"  ], # R[a] = R[a].send(Syms[b]) (no args)
      ["SENDB",      "BBB" ], # R[a] = R[a].send(Syms[b],R[a+1]..,R[a+n+1]:R[a+n+2]..,&R[a+n+2k+1])
      ["CALL",       "Z"   ], # self.call(*, **, &) (But overlay the current call frame; tailcall)
      ["BLKCALL",    "BB"  ], # R[a] = R[a].call(R[a+1],... ,R[a+b]); direct block call
      ["SUPER",      "BB"  ], # R[a] = super(R[a+1],... ,R[a+b+1])
      ["ARGARY",     "BS"  ], # R[a] = argument array (16=m5:r1:m5:d1:lv4)
      ["ENTER",      "W"   ], # arg setup according to flags (24=n1:m5:o5:r1:m5:k5:d1:b1)
      ["KEY_P",      "BB"  ], # R[a] = kdict.key?(Syms[b])
      ["KEYEND",     "Z"   ], # raise unless kdict.empty?
      ["KARG",       "BB"  ], # R[a] = kdict[Syms[b]]; kdict.delete(Syms[b])
      ["RETURN",     "B"   ], # return R[a] (normal)
      ["RETURN_BLK", "B"   ], # return R[a] (in-block return)
      ["RETSELF",    "Z"   ], # return self
      ["RETNIL",     "Z"   ], # return nil
      ["RETTRUE",    "Z"   ], # return true
      ["RETFALSE",   "Z"   ], # return false
      ["BREAK",      "B"   ], # break R[a]
      ["BLKPUSH",    "BS"  ], # R[a] = block (16=m5:r1:m5:d1:lv4)
      ["ADD",        "B"   ], # R[a] = R[a]+R[a+1]
      ["ADDI",       "BB"  ], # R[a] = R[a]+mrb_int(b)
      ["SUB",        "B"   ], # R[a] = R[a]-R[a+1]
      ["SUBI",       "BB"  ], # R[a] = R[a]-mrb_int(b)
      ["ADDILV",     "BBB" ], # R[a] = R[a]+mrb_int(c); R[b],R[b+1] for method call
      ["SUBILV",     "BBB" ], # R[a] = R[a]-mrb_int(c); R[b],R[b+1] for method call
      ["MUL",        "B"   ], # R[a] = R[a]*R[a+1]
      ["DIV",        "B"   ], # R[a] = R[a]/R[a+1]
      ["EQ",         "B"   ], # R[a] = R[a]==R[a+1]
      ["LT",         "B"   ], # R[a] = R[a]<R[a+1]
      ["LE",         "B"   ], # R[a] = R[a]<=R[a+1]
      ["GT",         "B"   ], # R[a] = R[a]>R[a+1]
      ["GE",         "B"   ], # R[a] = R[a]>=R[a+1]
      ["ARRAY",      "BB"  ], # R[a] = ary_new(R[a],R[a+1]..R[a+b])
      ["ARRAY2",     "BBB" ], # R[a] = ary_new(R[b],R[b+1]..R[b+c])
      ["ARYCAT",     "B"   ], # ary_cat(R[a],R[a+1])
      ["ARYPUSH",    "BB"  ], # ary_push(R[a],R[a+1]..R[a+b])
      ["ARYSPLAT",   "B"   ], # R[a] = ary_splat(R[a])
      ["AREF",       "BBB" ], # R[a] = R[b][c]
      ["ASET",       "BBB" ], # R[b][c] = R[a]
      ["APOST",      "BBB" ], # *R[a],R[a+1]..R[a+c] = R[a][b..]
      ["INTERN",     "B"   ], # R[a] = intern(R[a])
      ["SYMBOL",     "BB"  ], # R[a] = intern(Pool[b])
      ["STRING",     "BB"  ], # R[a] = str_dup(Pool[b])
      ["STRCAT",     "B"   ], # str_cat(R[a],R[a+1])
      ["HASH",       "BB"  ], # R[a] = hash_new(R[a],R[a+1]..R[a+b*2-1])
      ["HASHADD",    "BB"  ], # hash_push(R[a],R[a+1]..R[a+b*2])
      ["HASHCAT",    "B"   ], # R[a] = hash_cat(R[a],R[a+1])
      ["LAMBDA",     "BB"  ], # R[a] = lambda(Irep[b],L_LAMBDA)
      ["BLOCK",      "BB"  ], # R[a] = lambda(Irep[b],L_BLOCK)
      ["METHOD",     "BB"  ], # R[a] = lambda(Irep[b],L_METHOD)
      ["RANGE_INC",  "B"   ], # R[a] = range_new(R[a],R[a+1],FALSE)
      ["RANGE_EXC",  "B"   ], # R[a] = range_new(R[a],R[a+1],TRUE)
      ["OCLASS",     "B"   ], # R[a] = ::Object
      ["CLASS",      "BB"  ], # R[a] = newclass(R[a],Syms[b],R[a+1])
      ["MODULE",     "BB"  ], # R[a] = newmodule(R[a],Syms[b])
      ["EXEC",       "BB"  ], # R[a] = blockexec(R[a],Irep[b])
      ["DEF",        "BB"  ], # R[a].newmethod(Syms[b],R[a+1]); R[a] = Syms[b]
      ["TDEF",       "BBB" ], # target_class.newmethod(Syms[b],Irep[c]); R[a] = Syms[b]
      ["SDEF",       "BBB" ], # R[a].singleton_class.newmethod(Syms[b],Irep[c]); R[a] = Syms[b]
      ["ALIAS",      "BB"  ], # alias_method(target_class,Syms[a],Syms[b])
      ["UNDEF",      "B"   ], # undef_method(target_class,Syms[a])
      ["SCLASS",     "B"   ], # R[a] = R[a].singleton_class
      ["TCLASS",     "B"   ], # R[a] = target_class
      ["DEBUG",      "BBB" ], # print a,b,c
      ["ERR",        "B"   ], # raise(LocalJumpError, Pool[a])
      ["EXT1",       "Z"   ], # make 1st operand (a) 16bit
      ["EXT2",       "Z"   ], # make 2nd operand (b) 16bit
      ["EXT3",       "Z"   ], # make 1st and 2nd operands 16bit
      ["STOP",       "Z"   ], # stop VM
    ].freeze
    NAMES = TABLE.map(&:first).freeze
    FORMATS = TABLE.to_h.freeze
    NUM = NAMES.each_with_index.to_h.freeze
    EXT = { "EXT1" => 1, "EXT2" => 2, "EXT3" => 3 }.freeze

    Insn = Struct.new(:pc, :name, :a, :b, :c, :next_pc)

    module_function

    # iseq (バイト列) の pc から1命令。EXT は次の命令と合わせて1つにする (vm.c と同じ)
    def decode(iseq, pc)
      start = pc
      ext = 0
      name = NAMES.fetch(iseq.getbyte(pc)) { raise ArgumentError, "bad opcode #{iseq.getbyte(pc)} at #{pc}" }
      if EXT.key?(name)
        ext = EXT[name]
        pc += 1
        name = NAMES.fetch(iseq.getbyte(pc))
        raise ArgumentError, "EXT before EXT at #{start}" if EXT.key?(name)
      end
      pc += 1
      rd = lambda do |kind|
        case kind
        when :b then v = iseq.getbyte(pc); pc += 1
        when :s then v = (iseq.getbyte(pc) << 8) | iseq.getbyte(pc + 1); pc += 2
        when :w then v = (iseq.getbyte(pc) << 16) | (iseq.getbyte(pc + 1) << 8) | iseq.getbyte(pc + 2); pc += 3
        end
        v
      end
      wa = ext == 1 || ext == 3 ? :s : :b # EXT1 / EXT3 は a を S に
      wb = ext == 2 || ext == 3 ? :s : :b # EXT2 / EXT3 は b を S に
      a = b = c = nil
      case FORMATS.fetch(name)
      when "Z"
      when "B" then a = rd.(ext == 1 ? :s : :b) # FETCH_B_3 は FETCH_B のまま (opcode.h)
      when "BB" then a = rd.(wa); b = rd.(wb)
      when "BBB" then a = rd.(wa); b = rd.(wb); c = rd.(:b)
      when "BS" then a = rd.(wa); b = rd.(:s)
      when "BSS" then a = rd.(wa); b = rd.(:s); c = rd.(:s)
      when "S" then a = rd.(:s)
      when "W" then a = rd.(:w)
      end
      Insn.new(start, name, a, b, c, pc)
    end
  end
end
