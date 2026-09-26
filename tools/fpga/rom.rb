# .mrb (RITE0400) を CPU コアの ROM イメージ ($readmemh) にする。
#
# ROM は1命令1語の固定長 48bit (docs/spec.md §10「ROM 形式」):
#   [47:40] op  mruby の opcode 番号
#   [39:32] a
#   [31:16] b   BB の b / BS の s / S の s / BSS の上位16bit
#   [15:0]  c   BBB の c / BSS の下位16bit
# 変換で済ませること:
#   - ジャンプ先は mruby の「次の命令からのバイト相対」から、ROM の絶対語アドレスにする
#   - GETGV / SETGV の Syms[b] は io_map.rb のポート番号にする
#   - 未対応の命令・子 irep・pool・未知のグローバル変数は、場所を示して止まる
#
# 変換器の一部として PicoRuby でも走る (isa.rb の注記)。isa.rb / io_map.rb / rite.rb を先に読み込んでおくこと。
module FpgaRom
  class Error < StandardError; end

  WORD_BITS = 48
  HEX_DIGITS = WORD_BITS / 4
  # ROM の空き。op 0xff は未対応命令なので、プログラムの外へ出たコアはエラーで止まる
  PAD = (1 << WORD_BITS) - 1

  class Word
    attr_reader :pc, :insn, :op, :a, :b, :c, :irep

    def initialize(pc, insn, op, a, b, c, irep = nil)
      @pc = pc
      @insn = insn
      @op = op
      @a = a
      @b = b
      @c = c
      @irep = irep
    end

    def value
      (op << 40) | ((a & 0xFF) << 32) | ((b & 0xFFFF) << 16) | (c & 0xFFFF)
    end

    # 48bit を 16bit ずつ書く (PicoRuby の format は 32bit を超える幅に頼らない)
    def hex
      format("%02x%02x%04x%04x", op & 0xFF, a & 0xFF, b & 0xFFFF, c & 0xFFFF)
    end
  end

  class Image
    attr_reader :words, :nregs, :ireps

    def initialize(words, nregs, ireps)
      @words = words
      @nregs = nregs
      @ireps = ireps
    end

    def hex
      out = ""
      words.each { |w| out << w.hex << "\n" }
      out
    end

    # 人が読む一覧。irep ごとに見出しを付け、pc と元の iseq のバイト位置を並べる。
    def listing
      out = ""
      words.each do |w|
        ir = w.irep
        out << format("# irep %d  nregs %d\n", ir.index, ir.nregs) if w.pc == ir.base
        out << format("%4d  %03d  %-9s a=%-3d b=%-5d c=%-5d  %s\n", w.pc, w.insn.addr, w.insn.name, w.a, w.b, w.c, w.hex)
      end
      out
    end
  end

  def self.byte_addr(addr)
    format("%03d", addr)
  end

  # irep を先に親、次に子の順 (深さ優先) に並べる
  def self.flatten(irep, list)
    irep.index = list.size
    list << irep
    irep.reps.each { |c| flatten(c, list) }
    list
  end

  def self.where(irep, insn)
    irep.index == 0 ? "byte #{byte_addr(insn.addr)}" : "irep #{irep.index} byte #{byte_addr(insn.addr)}"
  end

  def self.from_binary(bin, source = "(mrb)", max_regs = nil)
    top = Rite.parse(bin)
    ireps = flatten(top, [])
    decoded = []
    base = 0
    ireps.each do |ir|
      raise Error, "#{source}: irep #{ir.index} has #{ir.plen} pool entr(ies) (strings / big literals are not supported)" if ir.plen > 0
      raise Error, "#{source}: irep #{ir.index} has catch handlers (exceptions are not supported)" if ir.clen > 0
      if max_regs && ir.nregs > max_regs
        raise Error, "#{source}: irep #{ir.index} needs #{ir.nregs} registers, the core has #{max_regs}"
      end
      ir.base = base
      insns = Rite.decode(ir.iseq)
      decoded << insns
      base += insns.size
    end

    bad = []
    ireps.each_with_index do |ir, i|
      decoded[i].each { |insn| bad << "#{insn.name} at #{where(ir, insn)}" unless FpgaIsa.supported?(insn.name) }
    end
    raise Error, "#{source}: unsupported instruction(s): #{bad.join(', ')}" unless bad.empty?

    ctx = Context.new(source, methods(ireps, decoded, source), {})
    words = []
    ireps.each_with_index do |ir, i|
      pc_of = {}
      decoded[i].each_with_index { |insn, k| pc_of[insn.addr] = ir.base + k }
      decoded[i].each_with_index { |insn, k| words << encode(insn, ir.base + k, pc_of, ir, ctx) }
    end
    Image.new(words, top.nregs, ireps)
  end

  # 変換中に持ち回るもの: メソッド名 -> 呼び出し先の irep、定数名 -> 番号
  class Context
    attr_reader :source, :methods, :consts

    def initialize(source, methods, consts)
      @source = source
      @methods = methods
      @consts = consts
    end
  end

  # TDEF (def) を全部拾い、メソッド名 -> 中身の irep にする。同じ名前の再定義は止める (静的に解決するため)
  def self.methods(ireps, decoded, source)
    table = {}
    ireps.each_with_index do |ir, i|
      decoded[i].each do |insn|
        next unless insn.name == "TDEF"
        sym = ir.syms[insn.operands[1]]
        if table[sym]
          raise Error, "#{source}: #{sym} is defined twice (#{where(ir, insn)}); methods are resolved statically"
        end
        table[sym] = ir.reps[insn.operands[2]]
      end
    end
    table
  end

  def self.encode(insn, pc, pc_of, irep, ctx)
    source = ctx.source
    ops = insn.operands
    a = 0
    b = 0
    c = 0
    case insn.op.fmt
    when "B"
      a = ops[0]
    when "BB", "BS"
      a = ops[0]
      b = ops[1]
    when "BBB", "BSS"
      a = ops[0]
      b = ops[1]
      c = ops[2]
    when "S"
      b = ops[0]
    when "W"
      a = ops[0]
    end
    name = insn.name

    if FpgaIsa::JUMPS.include?(name)
      # mruby: pc は operand を読み終えた位置 (次の命令) から int16 で進む
      rel = b >= 0x8000 ? b - 0x10000 : b
      target = insn.next_addr + rel
      b = pc_of[target]
      unless b
        raise Error, "#{source}: #{name} at #{where(irep, insn)} jumps to byte #{target}, not an instruction boundary"
      end
    end

    if name == "GETGV" || name == "SETGV"
      sym = irep.syms[b]
      port = FpgaIoMap.fetch(sym)
      unless port
        raise Error, "#{source}: #{name} at #{where(irep, insn)} uses #{sym}, " \
                     "which is not in tools/fpga/io_map.rb (known: #{FpgaIoMap::BY_NAME.keys.join(', ')})"
      end
      if name == "SETGV" && port.dir == :in
        raise Error, "#{source}: SETGV at #{where(irep, insn)} writes #{sym}, which is an input port"
      end
      b = port.num
    end

    if name == "GETCONST" || name == "SETCONST"
      sym = irep.syms[b]
      slot = ctx.consts[sym]
      unless slot
        slot = ctx.consts.size
        raise Error, "#{source}: too many constants (the core has #{FpgaIsa::NCONST}) at #{sym}" if slot >= FpgaIsa::NCONST
        ctx.consts[sym] = slot
      end
      b = slot
    end

    # TDEF: 呼び出し先は変換時に決めたので、実行時は R[a] = nil だけ (mruby はメソッド名の Symbol)
    if name == "TDEF"
      b = 0
      c = 0
    end

    # SSEND / SSEND0: b = 呼び出し先の先頭 pc、c = (呼び出し先の nregs << 8) | 引数の数
    if name == "SSEND" || name == "SSEND0"
      sym = irep.syms[b]
      argc = name == "SSEND" ? c & 0xF : 0
      if name == "SSEND" && (c >> 4) != 0
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with keyword arguments (not supported)"
      end
      raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with a splat (not supported)" if argc == 15
      callee = ctx.methods[sym]
      unless callee
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is not a method defined with def in this program " \
                     "(methods are resolved statically; built-in methods like puts are not supported)"
      end
      b = callee.base
      c = (callee.nregs << 8) | argc
    end

    # SEND / SEND0: b = 組み込みメソッドの番号 (isa.rb の BUILTINS)、c = 引数の数
    if name == "SEND" || name == "SEND0"
      sym = irep.syms[b]
      argc = name == "SEND" ? c & 0xF : 0
      id = FpgaIsa.builtin(sym, argc)
      if name == "SEND" && (c >> 4) != 0
        id = nil
      end
      unless id
        raise Error, "#{source}: .#{sym} with #{argc} argument(s) at #{where(irep, insn)} is not a supported method " \
                     "(supported: #{FpgaIsa::BUILTINS.map { |n, k| "#{n}/#{k}" }.join(' ')})"
      end
      b = id
      c = argc
    end

    # ENTER: 必須の引数だけ。a = その数
    if name == "ENTER"
      aspec = ops[0]
      m1 = (aspec >> 18) & 0x1F
      if (aspec & ~(0x1F << 18)) != 0
        raise Error, "#{source}: method at #{where(irep, insn)} takes optional, rest, keyword or block parameters " \
                     "(only required parameters are supported)"
      end
      a = m1
    end

    Word.new(pc, insn, insn.op.num, a, b, c, irep)
  end

  # ROM の1語を (op, a, b, c) に戻す。参照インタプリタと trace の表示が使う。
  def self.unpack(value)
    [(value >> 40) & 0xFF, (value >> 32) & 0xFF, (value >> 16) & 0xFFFF, value & 0xFFFF]
  end
end
