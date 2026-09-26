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
    attr_reader :pc, :insn, :op, :a, :b, :c

    def initialize(pc, insn, op, a, b, c)
      @pc = pc
      @insn = insn
      @op = op
      @a = a
      @b = b
      @c = c
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
    attr_reader :words, :nregs, :irep

    def initialize(words, nregs, irep)
      @words = words
      @nregs = nregs
      @irep = irep
    end

    def hex
      out = ""
      words.each { |w| out << w.hex << "\n" }
      out
    end

    # 人が読む一覧。pc と元の iseq のバイト位置を並べる。
    def listing
      out = ""
      words.each do |w|
        out << format("%4d  %03d  %-9s a=%-3d b=%-5d c=%-5d  %s\n", w.pc, w.insn.addr, w.insn.name, w.a, w.b, w.c, w.hex)
      end
      out
    end
  end

  def self.byte_addr(addr)
    format("%03d", addr)
  end

  def self.from_binary(bin, source = "(mrb)", max_regs = nil)
    irep = Rite.parse(bin)
    raise Error, "#{source}: has #{irep.rlen} child irep(s) (method/block definitions are not supported)" if irep.rlen > 0
    raise Error, "#{source}: has #{irep.plen} pool entr(ies) (strings / big literals are not supported)" if irep.plen > 0
    raise Error, "#{source}: has catch handlers (exceptions are not supported)" if irep.clen > 0
    if max_regs && irep.nregs > max_regs
      raise Error, "#{source}: needs #{irep.nregs} registers, the core has #{max_regs}"
    end

    insns = Rite.decode(irep.iseq)
    bad = insns.select { |i| !FpgaIsa.supported?(i.name) }
    unless bad.empty?
      where = bad.map { |i| "#{i.name} at byte #{byte_addr(i.addr)}" }.join(", ")
      raise Error, "#{source}: unsupported instruction(s): #{where}"
    end

    pc_of = {}
    insns.each_with_index { |insn, pc| pc_of[insn.addr] = pc }
    words = []
    insns.each_with_index { |insn, pc| words << encode(insn, pc, pc_of, irep, source) }
    Image.new(words, irep.nregs, irep)
  end

  def self.encode(insn, pc, pc_of, irep, source)
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
    end

    if FpgaIsa::JUMPS.include?(insn.name)
      # mruby: pc は operand を読み終えた位置 (次の命令) から int16 で進む
      rel = b >= 0x8000 ? b - 0x10000 : b
      target = insn.next_addr + rel
      b = pc_of[target]
      unless b
        raise Error, "#{source}: #{insn.name} at byte #{byte_addr(insn.addr)} jumps to byte #{target}, not an instruction boundary"
      end
    end

    if insn.name == "GETGV" || insn.name == "SETGV"
      sym = irep.syms[b]
      port = FpgaIoMap.fetch(sym)
      unless port
        raise Error, "#{source}: #{insn.name} at byte #{byte_addr(insn.addr)} uses #{sym}, " \
                     "which is not in tools/fpga/io_map.rb (known: #{FpgaIoMap::BY_NAME.keys.join(', ')})"
      end
      if insn.name == "SETGV" && port.dir == :in
        raise Error, "#{source}: SETGV at byte #{byte_addr(insn.addr)} writes #{sym}, which is an input port"
      end
      b = port.num
    end

    Word.new(pc, insn, insn.op.num, a, b, c)
  end

  # ROM の1語を (op, a, b, c) に戻す。参照インタプリタと trace の表示が使う。
  def self.unpack(value)
    [(value >> 40) & 0xFF, (value >> 32) & 0xFF, (value >> 16) & 0xFFFF, value & 0xFFFF]
  end
end
