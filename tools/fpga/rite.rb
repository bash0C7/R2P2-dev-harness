# .mrb (RITE0400) の読み取り器。FPGA の ROM 変換に要る分だけ読む。
#
# 形式は mruby/mruby の include/mruby/dump.h と src/load.c (read_irep_record_1):
#   header  "RITE" "0400" size(4) "MATZ" "0000"
#   section "IREP" size(4) "0400"
#     record size(4) nlocals(2) nregs(2) rlen(2) clen(2) ilen(4)
#            iseq(ilen) catch_handler(13 * clen)
#            plen(2) pool... slen(2) { len(2) bytes NUL }...
#     子 irep (rlen 個) が続く
#   section "DBG\0" size(4) (mrbc -g の時。caller の行とファイル。mruby の src/load.c の read_section_debug)
#     filenames: count(2) { len(2) bytes }...
#     irep ごと (IREP と同じ前置の順): record size(4) flen(2)
#       { start_pos(4) filename の番号(2) line_entry_count(4) line_type(1) lines... }...
#     lines は packed_map (type 2) だけ読む: {pos の差, 行の差} の可変長の整数の列 (mruby の debug.c の debug_get_line)
#   "END\0"
# 数値はすべて big endian。
#
# 変換器の一部として PicoRuby でも走る (isa.rb の注記)。isa.rb を先に読み込んでおくこと。
module Rite
  class Error < StandardError; end

  class Irep
    attr_reader :nlocals, :nregs, :rlen, :clen, :iseq, :plen, :pool, :syms, :reps
    # catch handler: [[種類 (0 rescue / 1 ensure), begin, end, target], ...] (iseq のバイト位置、.mrb の並びのまま)
    attr_accessor :catches
    # rom.rb が並べた時の番号と、ROM での先頭の語アドレス
    attr_accessor :index, :base
    # DBG の section (mrbc -g): [[start_pos, ファイル名, [[pos, 行], ...]], ...] (start_pos の順)。無ければ nil
    attr_accessor :debug

    # iseq のバイト位置 pc の命令の [ファイル名, 行] (mruby の mrb_debug_get_position と同じ)。debug 情報が無ければ nil
    def position(pc)
      return nil unless @debug
      file = nil
      @debug.each { |f| file = f if f[0] <= pc }
      return nil unless file
      line = 0
      file[2].each do |pos, diff|
        break if pc < pos
        line += diff
      end
      [file[1], line]
    end

    # pool: [[:str, バイト列] / [:int, 整数] / [:float, 上位 32bit, 下位 32bit] / [:bigint], ...]
    def initialize(nlocals, nregs, rlen, clen, iseq, pool, syms, reps)
      @nlocals = nlocals
      @nregs = nregs
      @rlen = rlen
      @clen = clen
      @iseq = iseq
      @plen = pool.size
      @pool = pool
      @syms = syms
      @reps = reps
      @catches = []
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
    top = read_irep(bin, pos + 12)[0] # ident, size, rite_version
    # 続く section: DBG なら irep に付ける。LVAR などは読まない
    pos += u32(bin, pos + 4)
    while pos + 8 <= bin.bytesize
      sec = bin.byteslice(pos, 4)
      break if sec == "END\0"
      read_debug(bin, pos + 8, top) if sec == "DBG\0"
      pos += u32(bin, pos + 4)
    end
    top
  end

  # DBG の section の中身 (見出しの後から) を読み、irep に前置の順で付ける
  def self.read_debug(bin, pos, top)
    names = []
    u16(bin, pos).times do
      pos += 2
      len = u16(bin, pos)
      names << bin.byteslice(pos + 2, len)
      pos += len
    end
    pos += 2
    order = []
    stack = [top]
    until stack.empty?
      ir = stack.shift
      order << ir
      stack = ir.reps + stack
    end
    order.each do |ir|
      rec = pos
      files = []
      p = pos + 6
      u16(bin, pos + 4).times do
        start = u32(bin, p)
        name = names[u16(bin, p + 4)]
        count = u32(bin, p + 6)
        type = bin.getbyte(p + 10)
        raise Error, "debug line type #{type} is not supported (mrbc writes packed_map)" unless type == 2
        entries = []
        q = p + 11
        pend = q + count
        at = 0
        while q < pend
          d, q = packed_int(bin, q)
          at += d
          diff, q = packed_int(bin, q)
          entries << [at, diff]
        end
        files << [start, name, entries]
        p = pend
      end
      ir.debug = files
      pos = rec + u32(bin, rec)
    end
  end

  # mruby の mrb_packed_int_decode: 7bit ずつ、上の bit が 1 なら続く。[値, 次の位置]
  def self.packed_int(bin, pos)
    n = 0
    shift = 0
    while true
      b = bin.getbyte(pos)
      n |= (b & 0x7F) << shift
      pos += 1
      shift += 7
      break if b < 0x80 || shift >= 32
    end
    [n, pos]
  end

  # irep を1つ読み、続く子 irep (rlen 個) も再帰的に読む。[irep, 次の位置] を返す
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
    pos += ilen
    catches = []
    clen.times do
      catches << [bin.getbyte(pos), u32(bin, pos + 1), u32(bin, pos + 5), u32(bin, pos + 9)]
      pos += 13
    end

    plen = u16(bin, pos)
    pos += 2
    pool = []
    plen.times do
      entry, pos = read_pool(bin, pos)
      pool << entry
    end

    syms = []
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

    reps = []
    rlen.times do
      child, pos = read_irep(bin, pos)
      reps << child
    end
    irep = Irep.new(nlocals, nregs, rlen, clen, iseq, pool, syms, reps)
    irep.catches = catches
    [irep, pos]
  end

  # mruby の src/load.c の POOL BLOCK を1つ読む。[中身, 次の位置]
  def self.read_pool(bin, pos)
    tt = bin.getbyte(pos)
    pos += 1
    case tt
    when 1 # IREP_TT_INT32
      v = u32(bin, pos)
      [[:int, v >= 0x8000_0000 ? v - 0x1_0000_0000 : v], pos + 4]
    when 3 # IREP_TT_INT64 (PicoRuby の 64bit の Integer でもあふれないように、上位を符号付きにしてから掛ける)
      hi = u32(bin, pos)
      hi -= 0x1_0000_0000 if hi >= 0x8000_0000
      [[:int, hi * 0x1_0000_0000 + u32(bin, pos + 4)], pos + 8]
    when 5 # IREP_TT_FLOAT: double を little endian で。[:float, 上位 32bit, 下位 32bit]
      lo = bin.getbyte(pos) | (bin.getbyte(pos + 1) << 8) | (bin.getbyte(pos + 2) << 16) | (bin.getbyte(pos + 3) << 24)
      hi = bin.getbyte(pos + 4) | (bin.getbyte(pos + 5) << 8) | (bin.getbyte(pos + 6) << 16) | (bin.getbyte(pos + 7) << 24)
      [[:float, hi, lo], pos + 8]
    when 7 then [[:bigint], pos + bin.getbyte(pos) + 2]     # IREP_TT_BIGINT
    when 0, 2                                               # IREP_TT_STR, IREP_TT_SSTR
      len = u16(bin, pos)
      [[:str, bin.byteslice(pos + 2, len)], pos + 2 + len + 1]
    else raise Error, "unknown pool type #{tt}"
    end
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
