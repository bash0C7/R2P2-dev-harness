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
require_relative "isa"

module Rite
  class Error < StandardError; end

  Irep = Struct.new(:nlocals, :nregs, :rlen, :clen, :iseq, :plen, :syms, keyword_init: true)

  # iseq を1命令ずつに割ったもの。addr は iseq 内のバイト位置、operands は ops.h の形式どおり。
  Insn = Struct.new(:addr, :op, :operands, :size) do
    def name
      op.name
    end

    def next_addr
      addr + size
    end
  end

  module_function

  def parse(bin)
    bin = bin.b
    raise Error, "not a RITE binary" unless bin[0, 4] == "RITE"
    ver = bin[4, 4]
    raise Error, "RITE#{ver} is not supported (expected RITE0400)" unless ver == "0400"

    pos = 20
    sec = bin[pos, 4]
    raise Error, "first section is #{sec.inspect}, expected \"IREP\"" unless sec == "IREP"
    pos += 12 # ident, size, rite_version
    read_irep(bin, pos)
  end

  def read_irep(bin, pos)
    u16 = ->(o) { bin.byteslice(o, 2).unpack1("n") }
    u32 = ->(o) { bin.byteslice(o, 4).unpack1("N") }

    pos += 4 # record size
    nlocals = u16.(pos)
    nregs   = u16.(pos + 2)
    rlen    = u16.(pos + 4)
    clen    = u16.(pos + 6)
    ilen    = u32.(pos + 8)
    pos += 12
    iseq = bin.byteslice(pos, ilen)
    pos += ilen + 13 * clen

    plen = u16.(pos)
    pos += 2
    # pool の中身は読まない (対応しないので、あれば rom.rb がエラーにする)。
    # pool があると syms の位置が分からないので、syms は空のまま返す。
    syms = []
    if plen.zero?
      slen = u16.(pos)
      pos += 2
      slen.times do
        len = u16.(pos)
        pos += 2
        if len == 0xFFFF
          syms << nil
        else
          syms << bin.byteslice(pos, len).force_encoding("UTF-8")
          pos += len + 1
        end
      end
    end

    Irep.new(nlocals: nlocals, nregs: nregs, rlen: rlen, clen: clen, iseq: iseq, plen: plen, syms: syms)
  end

  # iseq を命令列にする。未知の opcode は Error。
  def decode(iseq)
    bytes = iseq.bytes
    insns = []
    addr = 0
    while addr < bytes.size
      num = bytes[addr]
      op = FpgaIsa::OPS[num] or raise Error, "unknown opcode 0x#{num.to_s(16)} at byte #{addr}"
      n = op.operand_bytes
      raw = bytes[addr + 1, n]
      raise Error, "#{op.name} at byte #{addr} runs past the end of iseq" if raw.size < n
      insns << Insn.new(addr, op, split_operands(op.fmt, raw), 1 + n)
      addr += 1 + n
    end
    insns
  end

  def split_operands(fmt, raw)
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
