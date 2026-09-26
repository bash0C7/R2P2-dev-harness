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
require_relative "isa"
require_relative "rite"
require_relative "io_map"

module FpgaRom
  class Error < StandardError; end

  WORD_BITS = 48
  HEX_DIGITS = WORD_BITS / 4
  # ROM の空き。op 0xff は未対応命令なので、プログラムの外へ出たコアはエラーで止まる
  PAD = (1 << WORD_BITS) - 1

  Word = Struct.new(:pc, :insn, :op, :a, :b, :c) do
    def value
      (op << 40) | ((a & 0xFF) << 32) | ((b & 0xFFFF) << 16) | (c & 0xFFFF)
    end

    def hex
      format("%0#{HEX_DIGITS}x", value)
    end
  end

  Image = Struct.new(:words, :nregs, :irep, keyword_init: true) do
    def hex
      words.map { |w| "#{w.hex}\n" }.join
    end

    # 人が読む一覧。pc と元の iseq のバイト位置を並べる。
    def listing
      words.map do |w|
        format("%4d  %03d  %-9s a=%-3d b=%-5d c=%-5d  %s\n", w.pc, w.insn.addr, w.insn.name, w.a, w.b, w.c, w.hex)
      end.join
    end
  end

  module_function

  def from_file(path, max_regs: nil)
    from_binary(File.binread(path), source: path, max_regs: max_regs)
  end

  def from_binary(bin, source: "(mrb)", max_regs: nil)
    irep = Rite.parse(bin)
    raise Error, "#{source}: has #{irep.rlen} child irep(s) (method/block definitions are not supported)" if irep.rlen.positive?
    raise Error, "#{source}: has #{irep.plen} pool entr(ies) (strings / big literals are not supported)" if irep.plen.positive?
    raise Error, "#{source}: has catch handlers (exceptions are not supported)" if irep.clen.positive?
    if max_regs && irep.nregs > max_regs
      raise Error, "#{source}: needs #{irep.nregs} registers, the core has #{max_regs}"
    end

    insns = Rite.decode(irep.iseq)
    bad = insns.reject { |i| FpgaIsa.supported?(i.name) }
    unless bad.empty?
      where = bad.map { |i| "#{i.name} at byte #{format('%03d', i.addr)}" }.join(", ")
      raise Error, "#{source}: unsupported instruction(s): #{where}"
    end

    pc_of = insns.each_with_index.to_h { |insn, pc| [insn.addr, pc] }
    words = insns.each_with_index.map { |insn, pc| encode(insn, pc, pc_of, irep, source) }
    Image.new(words: words, nregs: irep.nregs, irep: irep)
  end

  def encode(insn, pc, pc_of, irep, source)
    ops = insn.operands
    a = b = c = 0
    case insn.op.fmt
    when "Z"
      nil
    when "B"
      a = ops[0]
    when "BB"
      a, b = ops
    when "BBB"
      a, b, c = ops
    when "BS"
      a, b = ops
    when "BSS"
      a, b, c = ops
    when "S"
      b = ops[0]
    end

    if FpgaIsa::JUMPS.include?(insn.name)
      # mruby: pc は operand を読み終えた位置 (次の命令) から int16 で進む
      rel = b >= 0x8000 ? b - 0x10000 : b
      target = insn.next_addr + rel
      b = pc_of[target] or
        raise Error, "#{source}: #{insn.name} at byte #{format('%03d', insn.addr)} jumps to byte #{target}, not an instruction boundary"
    end

    if %w[GETGV SETGV].include?(insn.name)
      sym = irep.syms[b]
      port = FpgaIoMap.fetch(sym) or
        raise Error, "#{source}: #{insn.name} at byte #{format('%03d', insn.addr)} uses #{sym}, " \
                     "which is not in tools/fpga/io_map.rb (known: #{FpgaIoMap::BY_NAME.keys.join(', ')})"
      if insn.name == "SETGV" && port.dir == :in
        raise Error, "#{source}: SETGV at byte #{format('%03d', insn.addr)} writes #{sym}, which is an input port"
      end
      b = port.num
    end

    Word.new(pc, insn, insn.op.num, a, b, c)
  end

  # ROM の1語を (op, a, b, c) に戻す。参照インタプリタと trace の表示が使う。
  def unpack(value)
    [(value >> 40) & 0xFF, (value >> 32) & 0xFF, (value >> 16) & 0xFFFF, value & 0xFFFF]
  end

  def read_hex(path)
    File.readlines(path, chomp: true).reject { |l| l.strip.empty? || l.start_with?("//") }.map { |l| l.to_i(16) }
  end
end
