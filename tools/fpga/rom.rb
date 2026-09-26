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

    ctx = Context.new(source, methods(ireps, decoded, source), {}, {}, {}, {}, decoded)
    ctx.lambdas = {}
    block_sites(ireps, decoded, ctx)

    # 1命令が何語になるかを数えて、irep と命令の先頭 pc を決める (iterator などは数語に展開する)
    base = 0
    pc_of = []
    ireps.each_with_index do |ir, i|
      ir.base = base
      table = {}
      decoded[i].each_with_index do |insn, k|
        table[insn.addr] = base
        specs = lowered(insn, ir, k, base, ctx)
        base += specs ? specs.size : 1
      end
      pc_of << table
    end

    words = []
    ireps.each_with_index do |ir, i|
      decoded[i].each_with_index do |insn, k|
        pc = pc_of[i][insn.addr]
        specs = lowered(insn, ir, k, pc, ctx)
        if specs
          specs.each_with_index do |(name, a, b, c), n|
            words << Word.new(pc + n, insn, FpgaIsa.op(name).num, a, b, c, ir, n == 0)
          end
        else
          words << encode(insn, pc, pc_of[i], ir, ctx, k)
        end
      end
    end
    Image.new(words, top.nregs, ireps)
  end

  # 変換中に持ち回るもの: メソッド名 -> 呼び出し先の irep、定数名 -> 番号、
  # SENDB / SSENDB (irep と命令の番号 -> Site)、ブロックの irep の番号 -> それを作った irep、
  # iterator に直接渡したブロックの irep の番号 -> Site (break の出口が決まる)
  class Context
    attr_reader :source, :methods, :consts, :sites, :parents, :direct, :decoded
    attr_accessor :lambdas # lambda にするブロックの irep の番号 -> true

    def initialize(source, methods, consts, sites, parents, direct, decoded)
      @source = source
      @methods = methods
      @consts = consts
      @sites = sites
      @parents = parents
      @direct = direct
      @decoded = decoded
    end
  end

  # ブロックを取る呼び出し。kind は iterator の名前か "method" (def したメソッドにブロックを渡す)
  class Site
    attr_reader :parent, :a, :kind, :argc, :callee
    attr_accessor :brk_pc

    def initialize(parent, a, kind, argc, callee)
      @parent = parent
      @a = a
      @kind = kind
      @argc = argc
      @callee = callee
    end

    # Proc は R[a + 引数の数 + 1]
    def proc_reg
      a + argc + 1
    end
  end

  def self.site_key(irep, k)
    "#{irep.index}:#{k}"
  end

  # BLOCK が作る irep の親を覚え、SENDB / SSENDB の種類を決める
  def self.block_sites(ireps, decoded, ctx)
    source = ctx.source
    ireps.each_with_index do |ir, i|
      insns = decoded[i]
      insns.each_with_index do |insn, k|
        if insn.name == "BLOCK" || insn.name == "LAMBDA"
          block = ir.reps[insn.operands[1]]
          ctx.parents[block.index] = ir
          ctx.lambdas[block.index] = true if insn.name == "LAMBDA"
          block_params(block, decoded[block.index], source)
          next
        end
        next unless insn.name == "SENDB" || insn.name == "SSENDB"
        a, symi, c = insn.operands
        sym = ir.syms[symi]
        argc = c & 0xF
        raise Error, "#{source}: #{sym} at #{where(ir, insn)} is called with keyword arguments or a splat (not supported)" if (c >> 4) != 0 || argc == 15
        callee = nil
        kind = nil
        if insn.name == "SSENDB" && ctx.methods[sym]
          kind = "method"
          callee = ctx.methods[sym]
        elsif FpgaIsa.iterator(sym, insn.name, argc)
          kind = sym
        end
        unless kind
          raise Error, "#{source}: #{sym} with a block at #{where(ir, insn)} is not supported " \
                       "(blocks go to def'd methods, times, upto, downto, loop, each, each_with_index, map, proc, lambda)"
        end
        site = Site.new(ir, a, kind, argc, callee)
        ctx.sites[site_key(ir, k)] = site
        # 直前の BLOCK で作ったブロックを iterator に渡すなら、その break は iterator の出口へ飛ぶ
        prev = k > 0 ? insns[k - 1] : nil
        if prev && prev.name == "BLOCK" && prev.operands[0] == site.proc_reg && !%w[method proc lambda].include?(kind)
          ctx.direct[ir.reps[prev.operands[1]].index] = site
        end
        # lambda { } に渡したブロックは lambda になる
        if prev && prev.name == "BLOCK" && prev.operands[0] == site.proc_reg && kind == "lambda"
          ctx.lambdas[ir.reps[prev.operands[1]].index] = true
        end
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

  # irep がブロックなら、それを囲むメソッド (か一番外) まで何段あるか。ブロックでなければ 0
  def self.block_depth(irep, ctx)
    d = 0
    cur = irep
    while ctx.parents[cur.index]
      cur = ctx.parents[cur.index]
      d += 1
    end
    [d, cur]
  end

  # irep から囲むメソッド (か一番外) までの間に lambda のブロックがあるか
  def self.lambda_between?(irep, ctx)
    cur = irep
    while ctx.parents[cur.index]
      return true if ctx.lambdas[cur.index]
      cur = ctx.parents[cur.index]
    end
    false
  end

  # ほかの命令の列に下げる命令なら [[名前, a, b, c], ...] を返す。そのまま1語にするなら nil
  def self.lowered(insn, ir, k, pc, ctx)
    site = ctx.sites[site_key(ir, k)]
    return expand_site(site, pc, ctx) if site
    if (insn.name == "SSEND0" || insn.name == "SSEND") && ir.syms[insn.operands[1]] == "block_given?" && !ctx.methods["block_given?"]
      # block_given? は、囲むメソッドのブロックの枠 (必須の引数の次) を BLKPUSH で読み、!! で true / false にする
      depth, method = block_depth(ir, ctx)
      m1 = method.index == 0 ? 0 : block_params(method, ctx.decoded[method.index], ctx.source)
      a = insn.operands[0]
      return [["BLKPUSH", a, m1 + 1, depth], ["SEND0", a, FpgaIsa.builtin("!", 0), 0], ["SEND0", a, FpgaIsa.builtin("!", 0), 0]]
    end
    nil
  end

  # iterator などを命令の列に展開する。break の飛び先 (Site#brk_pc) もここで決まる。
  # Proc は R[s + 引数の数 + 1]、その後ろにカウンタなど、さらに後ろ (f) がブロックのフレーム
  def self.expand_site(site, pc, ctx)
    s = site.a
    pr = site.proc_reg
    out = []
    case site.kind
    when "method"
      callee = site.callee
      return [["SSEND", s, callee.base || 0, (callee.nregs << 8) | 0x80 | site.argc]]
    when "proc", "lambda"
      return [["MOVE", s, pr, 0]]
    when "loop"
      f = pr + 1
      out << ["MOVE", f, pr, 0]
      out << ["BLKCALL", f, 0, 0]
      out << ["JMP", 0, pc, 0]
      site.brk_pc = pc + out.size
      out << ["MOVE", s, f, 0]
      return out
    end

    i = pr + 1                                  # カウンタ
    res = pr + 2                                # map の結果
    f = site.kind == "map" ? pr + 3 : pr + 2    # ブロックのフレーム
    array = %w[each each_with_index map].include?(site.kind)
    out << ["ARRAY", res, 0, 0] if site.kind == "map"
    if site.kind == "upto" || site.kind == "downto"
      out << ["MOVE", i, s, 0]
    else
      out << ["LOADI_0", i, 0, 0]
    end
    top = pc + out.size
    # 続けるか: times は i < n、upto は i <= 引数、downto は i >= 引数、配列は i < size
    out << ["MOVE", f, i, 0]
    if array
      out << ["MOVE", f + 1, s, 0]
      out << ["SEND0", f + 1, FpgaIsa.builtin("size", 0), 0]
    else
      out << ["MOVE", f + 1, site.kind == "times" ? s : s + 1, 0]
    end
    out << [{ "upto" => "LE", "downto" => "GE" }[site.kind] || "LT", f, 0, 0]
    jmpnot = out.size
    out << ["JMPNOT", f, 0, 0] # 出口は後で埋める
    nargs = 1
    if array
      out << ["MOVE", f, s, 0]
      out << ["MOVE", f + 1, i, 0]
      out << ["GETIDX", f, 0, 0]
      out << ["MOVE", f + 1, f, 0]
      if site.kind == "each_with_index"
        out << ["MOVE", f + 2, i, 0]
        nargs = 2
      end
    else
      out << ["MOVE", f + 1, i, 0]
    end
    out << ["MOVE", f, pr, 0]
    out << ["BLKCALL", f, nargs, 0]
    if site.kind == "map"
      out << ["MOVE", f + 1, f, 0]
      out << ["MOVE", f, res, 0]
      out << ["SEND", f, FpgaIsa.builtin("<<", 1), 1]
    end
    out << [site.kind == "downto" ? "SUBI" : "ADDI", i, 1, 0]
    out << ["JMP", 0, top, 0]
    done = pc + out.size
    out[jmpnot][2] = done
    out << ["MOVE", s, res, 0] if site.kind == "map" # map の結果。ほかは受け手 (R[s]) がそのまま結果
    out << ["JMP", 0, pc + out.size + 2, 0]
    site.brk_pc = pc + out.size
    out << ["MOVE", s, f, 0] # break: ブロックのフレームの R0 に置かれた値が結果
    out
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

    # SSEND / SSEND0: b = 呼び出し先の先頭 pc、c = (呼び出し先の nregs << 8) | 引数の数。
    # def したメソッドが無く、sleep_ms / sleep なら組み込み (SEND) にする
    if name == "SSEND" || name == "SSEND0"
      sym = irep.syms[b]
      argc = name == "SSEND" ? c & 0xF : 0
      if name == "SSEND" && (c >> 4) != 0
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with keyword arguments (not supported)"
      end
      raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with a splat (not supported)" if argc == 15
      callee = ctx.methods[sym]
      if !callee && FpgaIsa::SELF_BUILTINS.include?(sym) && FpgaIsa.builtin(sym, argc)
        return Word.new(pc, insn, FpgaIsa.op(argc.zero? ? "SEND0" : "SEND").num, a, FpgaIsa.builtin(sym, argc), argc, irep)
      end
      unless callee
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is not a method defined with def in this program " \
                     "(methods are resolved statically; built-in methods like puts are not supported)"
      end
      b = callee.base
      c = (callee.nregs << 8) | argc
    end

    # SEND / SEND0: b = 組み込みメソッドの番号 (isa.rb の BUILTINS)、c = 引数の数。
    # .call は Proc の呼び出し (BLKCALL a, 引数の数)
    if name == "SEND" || name == "SEND0"
      sym = irep.syms[b]
      argc = name == "SEND" ? c & 0xF : 0
      if sym == "call" && (name == "SEND0" || (c >> 4).zero?) && argc != 15
        return Word.new(pc, insn, FpgaIsa.op("BLKCALL").num, a, argc, 0, irep)
      end
      id = FpgaIsa::SELF_BUILTINS.include?(sym) ? nil : FpgaIsa.builtin(sym, argc)
      if name == "SEND" && (c >> 4) != 0
        id = nil
      end
      unless id
        raise Error, "#{source}: .#{sym} with #{argc} argument(s) at #{where(irep, insn)} is not a supported method " \
                     "(supported: #{FpgaIsa::BUILTINS.map { |n, k| "#{n}/#{k}" }.join(' ')} call)"
      end
      b = id
      c = argc
    end

    # ENTER: 必須の引数 (と &blk) だけ。a = 必須の引数の数。ブロックの ENTER は NOP にする
    # (Proc は引数の数を調べない。足りなければ nil、多ければ捨てる)
    if name == "ENTER"
      aspec = ops[0]
      m1 = (aspec >> 18) & 0x1F
      if (aspec & ~((0x1F << 18) | 1)) != 0
        raise Error, "#{source}: method at #{where(irep, insn)} takes optional, rest or keyword parameters " \
                     "(only required parameters and &block are supported)"
      end
      return Word.new(pc, insn, FpgaIsa.op("NOP").num, 0, 0, 0, irep) if ctx.parents[irep.index]
      a = m1
    end

    # BLOCK / LAMBDA: Proc を作る。b = ブロックの irep の先頭 pc、c = 引数の数 | lambda << 7 | nregs << 8
    if name == "BLOCK" || name == "LAMBDA"
      block = irep.reps[ops[1]]
      b = block.base
      c = block_params(block, ctx.decoded[block.index], source) | (ctx.lambdas[block.index] ? 0x80 : 0) | (block.nregs << 8)
      return Word.new(pc, insn, FpgaIsa.op("BLOCK").num, a, b, c, irep)
    end

    # GETUPVAR / SETUPVAR: 外側のフレームのレジスタ。b = 番号、c = フレームの深さ (mruby の深さ + 1)
    if name == "GETUPVAR" || name == "SETUPVAR"
      depth, = block_depth(irep, ctx)
      raise Error, "#{source}: #{name} at #{where(irep, insn)} reaches #{c + 1} levels out, the block is #{depth} deep" if c + 1 > depth
      c += 1
    end

    # BLKPUSH: 深さ lv のフレームのブロックの枠。b = 枠の番号 (1 + m1 + r + m2 + kd)、c = lv
    if name == "BLKPUSH"
      x = ops[1]
      b = 1 + ((x >> 11) & 0x3F) + ((x >> 10) & 1) + ((x >> 5) & 0x1F) + ((x >> 4) & 1)
      c = x & 0xF
    end

    # BREAK: iterator に直接渡したブロックなら、フレームを1つ畳んで iterator の出口 (b) へ (c = 0)。
    # def したメソッドや Proc に渡したブロックなら、作ったフレームまで畳む (c = 1)
    if name == "BREAK"
      raise Error, "#{source}: break at #{where(irep, insn)} is not inside a block" unless ctx.parents[irep.index]
      site = ctx.direct[irep.index]
      if site
        b = site.brk_pc
        c = 0
      else
        b = 0
        c = 1
      end
    end

    # RETURN_BLK: ブロックの中の return。c = 囲むメソッドのフレームの深さ (途中の lambda はコアが見つける)
    if name == "RETURN_BLK"
      depth, method = block_depth(irep, ctx)
      if method.index == 0 && !lambda_between?(irep, ctx)
        raise Error, "#{source}: return inside a block at #{where(irep, insn)} is not inside a method or a lambda"
      end
      c = depth
    end

    Word.new(pc, insn, insn.op.num, a, b, c, irep)
  end

  # ROM の1語を (op, a, b, c) に戻す。参照インタプリタと trace の表示が使う。
  def self.unpack(value)
    [(value >> 40) & 0xFF, (value >> 32) & 0xFF, (value >> 16) & 0xFFFF, value & 0xFFFF]
  end
end
