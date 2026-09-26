# .mrb (RITE0400) の読み取り器。FPGA の ROM 変換に要る分だけ読む。
#
# 形式は mruby/mruby の include/mruby/dump.h と src/load.c (read_irep_record_1):
#   header  "RITE" "0400" size(4) "MATZ" "0000"
#   section "IREP" size(4) "0400"
#     record size(4) nlocals(2) nregs(2) rlen(2) clen(2) ilen(4)
#            iseq(ilen) catch_handler(13 * clen)
#            plen(2) pool... slen(2) { len(2) bytes NUL }...
#     子 irep (rlen 個) が続く
#   "END\0"
# 数値はすべて big endian。
#
# 変換器の一部として PicoRuby でも走る (isa.rb の注記)。isa.rb を先に読み込んでおくこと。
module Rite
  class Error < StandardError; end

  class Irep
    attr_reader :nlocals, :nregs, :rlen, :clen, :iseq, :plen, :syms

    def initialize(nlocals, nregs, rlen, clen, iseq, plen, syms)
      @nlocals = nlocals
      @nregs = nregs
      @rlen = rlen
      @clen = clen
      @iseq = iseq
      @plen = plen
      @syms = syms
    end
  end

  # iseq を1命令ずつに割ったもの。addr は iseq 内のバイト位置、operands は ops.h の形式どおり。
  class Insn
    attr_reader :addr, :op, :operands, :size

    def initialize(addr, op, operands, size)
      @addr = addr
      @op = op
      @operands = operands
      @size = size
    end

    def name
      op.name
    end

    def next_addr
      addr + size
    end
  end

  def self.u16(bin, pos)
    (bin.getbyte(pos) << 8) | bin.getbyte(pos + 1)
  end

  def self.u32(bin, pos)
    (u16(bin, pos) << 16) | u16(bin, pos + 2)
  end

  def self.parse(bin)
    raise Error, "not a RITE binary" unless bin.bytesize >= 32 && bin.byteslice(0, 4) == "RITE"
    ver = bin.byteslice(4, 4)
    raise Error, "RITE#{ver} is not supported (expected RITE0400)" unless ver == "0400"

    pos = 20
    sec = bin.byteslice(pos, 4)
    raise Error, "first section is #{sec.inspect}, expected \"IREP\"" unless sec == "IREP"
    read_irep(bin, pos + 12) # ident, size, rite_version
  end

  def self.read_irep(bin, pos)
    pos += 4 # record size
    nlocals = u16(bin, pos)
    nregs   = u16(bin, pos + 2)
    rlen    = u16(bin, pos + 4)
    clen    = u16(bin, pos + 6)
    ilen    = u32(bin, pos + 8)
    pos += 12
    iseq = bin.byteslice(pos, ilen)
    raise Error, "iseq runs past the end of the binary" unless iseq && iseq.bytesize == ilen
    pos += ilen + 13 * clen

    plen = u16(bin, pos)
    pos += 2
    # pool の中身は読まない (対応しないので、あれば rom.rb がエラーにする)。
    # pool があると syms の位置が分からないので、syms は空のまま返す。
    syms = []
    if plen == 0
      slen = u16(bin, pos)
      pos += 2
      slen.times do
        len = u16(bin, pos)
        pos += 2
        if len == 0xFFFF
          syms << nil
        else
          syms << bin.byteslice(pos, len)
          pos += len + 1
        end
      end
    end

    Irep.new(nlocals, nregs, rlen, clen, iseq, plen, syms)
  end

  # iseq を命令列にする。未知の opcode は Error。
  def self.decode(iseq)
    insns = []
    addr = 0
    size = iseq.bytesize
    while addr < size
      num = iseq.getbyte(addr)
      op = FpgaIsa::OPS[num]
      raise Error, "unknown opcode 0x#{num.to_s(16)} at byte #{addr}" unless op
      n = op.operand_bytes
      raise Error, "#{op.name} at byte #{addr} runs past the end of iseq" if addr + 1 + n > size
      raw = []
      n.times { |i| raw << iseq.getbyte(addr + 1 + i) }
      insns << Insn.new(addr, op, split_operands(op.fmt, raw), 1 + n)
      addr += 1 + n
    end
    insns
  end

  def self.split_operands(fmt, raw)
    case fmt
    when "Z"   then []
    when "B"   then [raw[0]]
    when "BB"  then [raw[0], raw[1]]
    when "BBB" then [raw[0], raw[1], raw[2]]
    when "BS"  then [raw[0], (raw[1] << 8) | raw[2]]
    when "BSS" then [raw[0], (raw[1] << 8) | raw[2], (raw[3] << 8) | raw[4]]
    when "S"   then [(raw[0] << 8) | raw[1]]
    when "W"   then [(raw[0] << 16) | (raw[1] << 8) | raw[2]]
    else raise Error, "unknown operand format #{fmt}"
    end
  end
end
