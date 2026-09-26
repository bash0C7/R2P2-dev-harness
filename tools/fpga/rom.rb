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
    attr_reader :pc, :insn, :op, :a, :b, :c, :irep, :first

    # first: 元の命令を展開した語のうち先頭か (iterator は1命令が数語になる)
    def initialize(pc, insn, op, a, b, c, irep = nil, first = true)
      @pc = pc
      @insn = insn
      @op = op
      @a = a
      @b = b
      @c = c
      @irep = irep
      @first = first
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
        name = FpgaIsa::OPS[w.op].name
        from = name == w.insn.name ? "" : "  <- #{w.insn.name}"
        addr = w.first ? format("%03d", w.insn.addr) : "   "
        out << format("%4d  %s  %-9s a=%-3d b=%-5d c=%-5d  %s%s\n", w.pc, addr, name, w.a, w.b, w.c, w.hex, from)
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
    ireps.each do |ir|
      raise Error, "#{source}: irep #{ir.index} has #{ir.plen} pool entr(ies) (strings / big literals are not supported)" if ir.plen > 0
      raise Error, "#{source}: irep #{ir.index} has catch handlers (exceptions are not supported)" if ir.clen > 0
      if max_regs && ir.nregs > max_regs
        raise Error, "#{source}: irep #{ir.index} needs #{ir.nregs} registers, the core has #{max_regs}"
      end
      decoded << Rite.decode(ir.iseq)
    end

    bad = []
    ireps.each_with_index do |ir, i|
      decoded[i].each { |insn| bad << "#{insn.name} at #{where(ir, insn)}" unless FpgaIsa.convertible?(insn.name) }
    end
    raise Error, "#{source}: unsupported instruction(s): #{bad.join(', ')}" unless bad.empty?

    ctx = Context.new(source, methods(ireps, decoded, source), {}, {}, {})
    block_sites(ireps, decoded, ctx)

    # 1命令が何語になるかを数えて、irep と命令の先頭 pc を決める (iterator は数語に展開する)
    base = 0
    pc_of = []
    ireps.each_with_index do |ir, i|
      ir.base = base
      table = {}
      decoded[i].each_with_index do |insn, k|
        table[insn.addr] = base
        site = ctx.sites[site_key(ir, k)]
        if site
          site.pc = base
          words, brk = expand_iterator(site, base, 0)
          site.brk_pc = brk
          base += words.size
        else
          base += 1
        end
      end
      pc_of << table
    end

    words = []
    ireps.each_with_index do |ir, i|
      decoded[i].each_with_index do |insn, k|
        site = ctx.sites[site_key(ir, k)]
        if site
          entry = site.block.base
          specs, _brk = expand_iterator(site, site.pc, entry)
          specs.each_with_index do |(name, a, b, c), n|
            words << Word.new(site.pc + n, insn, FpgaIsa.op(name).num, a, b, c, ir, n == 0)
          end
        else
          words << encode(insn, pc_of[i][insn.addr], pc_of[i], ir, ctx, k)
        end
      end
    end
    Image.new(words, top.nregs, ireps)
  end

  # 変換中に持ち回るもの: メソッド名 -> 呼び出し先の irep、定数名 -> 番号、
  # ブロックを渡す SENDB / SSENDB (irep と命令の番号 -> Site)、ブロックの irep の番号 -> Site
  class Context
    attr_reader :source, :methods, :consts, :sites, :blocks

    def initialize(source, methods, consts, sites, blocks)
      @source = source
      @methods = methods
      @consts = consts
      @sites = sites
      @blocks = blocks
    end
  end

  # ブロックを渡して iterator を呼ぶ所。ブロックのフレームは呼んだフレームの bp + disp に置く
  class Site
    attr_reader :parent, :a, :kind, :block, :argc_given, :m1
    attr_accessor :pc, :brk_pc

    def initialize(parent, a, kind, block, argc_given, m1)
      @parent = parent
      @a = a
      @kind = kind
      @block = block
      @argc_given = argc_given
      @m1 = m1
    end

    # iterator が使う作業レジスタの後ろに、ブロックのフレームを置く
    def disp
      a + FRAME_OFFSET[kind]
    end
  end

  # R[a] 受け手 (loop は self)、R[a+1]... 引数とブロック。その後ろにカウンタ、その後ろがブロックのフレーム
  FRAME_OFFSET = { "times" => 3, "upto" => 4, "downto" => 4, "loop" => 2 }

  def self.site_key(irep, k)
    "#{irep.index}:#{k}"
  end

  # BLOCK の直後の SENDB / SSENDB だけを受け付け、iterator の種類とブロックの irep を決める
  def self.block_sites(ireps, decoded, ctx)
    source = ctx.source
    ireps.each_with_index do |ir, i|
      insns = decoded[i]
      insns.each_with_index do |insn, k|
        if insn.name == "BLOCK"
          nxt = insns[k + 1]
          unless nxt && (nxt.name == "SENDB" || nxt.name == "SSENDB")
            raise Error, "#{source}: BLOCK at #{where(ir, insn)} is not passed directly to times / upto / downto / loop " \
                         "(blocks are not values on this core)"
          end
          next
        end
        next unless insn.name == "SENDB" || insn.name == "SSENDB"
        a, symi, c = insn.operands
        sym = ir.syms[symi]
        argc = c & 0xF
        it = (c >> 4).zero? ? FpgaIsa.iterator(sym, insn.name, argc) : nil
        unless it
          raise Error, "#{source}: #{sym} with a block at #{where(ir, insn)} is not supported " \
                       "(only times, upto, downto and loop take blocks)"
        end
        prev = k > 0 ? insns[k - 1] : nil
        unless prev && prev.name == "BLOCK" && prev.operands[0] == a + argc + 1
          raise Error, "#{source}: #{sym} at #{where(ir, insn)} is not given a literal block"
        end
        block = ir.reps[prev.operands[1]]
        m1 = block_params(block, decoded[block.index], source)
        site = Site.new(ir, a, sym, block, it[3], m1)
        ctx.sites[site_key(ir, k)] = site
        ctx.blocks[block.index] = site
      end
    end
  end

  # ブロックの引数の数 (先頭の ENTER)。必須の引数だけを受け付ける
  def self.block_params(block, insns, source)
    enter = insns[0]
    return 0 unless enter && enter.name == "ENTER"
    aspec = enter.operands[0]
    if (aspec & ~(0x1F << 18)) != 0
      raise Error, "#{source}: block at #{where(block, enter)} takes optional, rest, keyword or block parameters " \
                   "(only required parameters are supported)"
    end
    (aspec >> 18) & 0x1F
  end

  # iterator を命令の列に展開する。[[名前, a, b, c], ...] と、break の飛び先の pc を返す。
  # entry はブロックの irep の先頭 pc。ブロックには m1 個の値を渡す (iterator が渡さない分は nil)
  def self.expand_iterator(site, pc, entry)
    s = site.a
    f = site.disp                       # ブロックのフレームの底 (呼んだフレームの R[f])
    call_c = (site.block.nregs << 8) | site.m1
    out = []
    args = lambda do |value_reg|
      site.m1.times do |j|
        if j == 0 && site.argc_given >= 1
          out << ["MOVE", f + 1, value_reg, 0]
        else
          out << ["LOADNIL", f + 1 + j, 0, 0]
        end
      end
      out << ["SSEND", f, entry, call_c]
    end

    if site.kind == "loop"
      top = pc
      args.call(nil)
      out << ["JMP", 0, top, 0]
      brk = pc + out.size
      out << ["MOVE", s, f, 0]
      return [out, brk]
    end

    # times: i = 0 から i < n、upto: i = 受け手から i <= 引数、downto: i = 受け手から i >= 引数
    i = s + FRAME_OFFSET[site.kind] - 1 # カウンタ
    if site.kind == "times"
      out << ["LOADI_0", i, 0, 0]
    else
      out << ["MOVE", i, s, 0]
    end
    top = pc + out.size
    out << ["MOVE", f, i, 0]
    out << ["MOVE", f + 1, site.kind == "times" ? s : s + 1, 0]
    out << [{ "times" => "LT", "upto" => "LE", "downto" => "GE" }[site.kind], f, 0, 0]
    jmpnot = out.size
    out << ["JMPNOT", f, 0, 0] # 出口は後で埋める
    args.call(i)
    out << [site.kind == "downto" ? "SUBI" : "ADDI", i, 1, 0]
    out << ["JMP", 0, top, 0]
    done = pc + out.size
    out[jmpnot][2] = done
    out << ["JMP", 0, done + 2, 0] # 普通に終わった: 受け手 (R[s]) がそのまま結果
    brk = pc + out.size
    out << ["MOVE", s, f, 0]       # break: ブロックのフレームの R0 に置かれた値が結果
    [out, brk]
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

  def self.encode(insn, pc, pc_of, irep, ctx, k = 0)
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

    # BLOCK: ブロックは値にしない (直後の SENDB / SSENDB が irep を直接呼ぶ)。R[a] = nil だけ
    return Word.new(pc, insn, FpgaIsa.op("LOADNIL").num, a, 0, 0, irep) if name == "BLOCK"

    # GETUPVAR / SETUPVAR: 外側のフレームのレジスタ。ブロックのフレームはそれを作ったフレームから
    # 変換時に決まる距離 (Site#disp) にあるので、「bp から下へ何本目」(b) にできる
    if name == "GETUPVAR" || name == "SETUPVAR"
      idx = b
      depth = c
      total = 0
      cur = irep
      (depth + 1).times do
        site = ctx.blocks[cur.index]
        raise Error, "#{source}: #{name} at #{where(irep, insn)} is not inside a block given to times / upto / downto / loop" unless site
        total += site.disp
        cur = site.parent
      end
      raise Error, "#{source}: #{name} at #{where(irep, insn)} reaches a register the block frame overlaps" if idx >= total
      b = total - idx
      c = 0
    end

    # BREAK: ブロックのフレームを畳み、iterator の break の出口へ飛ぶ
    if name == "BREAK"
      site = ctx.blocks[irep.index]
      raise Error, "#{source}: break at #{where(irep, insn)} is not inside a block given to times / upto / downto / loop" unless site
      b = site.brk_pc
    end

    Word.new(pc, insn, insn.op.num, a, b, c, irep)
  end

  # ROM の1語を (op, a, b, c) に戻す。参照インタプリタと trace の表示が使う。
  def self.unpack(value)
    [(value >> 40) & 0xFF, (value >> 32) & 0xFF, (value >> 16) & 0xFFFF, value & 0xFFFF]
  end
end
