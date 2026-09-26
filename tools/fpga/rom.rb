# .mrb (RITE0400) を CPU コアの ROM イメージ ($readmemh) にする。
#
# ROM は1命令1語の固定長 48bit (docs/spec.md §10「ROM 形式」):
#   [47:40] op  mruby の opcode 番号 (FPGA だけの命令は isa.rb の EXTRA)
#   [39:32] a
#   [31:16] b   BB の b / BS の s / S の s / BSS の上位16bit
#   [15:0]  c   BBB の c / BSS の下位16bit
# 並び: pc 0 は TABLE (メソッド表の位置と大きさ)、その後に irep を親・子の順、最後にメソッド表。
# 変換で済ませること:
#   - ジャンプ先は mruby の「次の命令からのバイト相対」から、ROM の絶対語アドレスにする
#   - GETGV / SETGV の Syms[b] は io_map.rb のポート番号にする
#   - シンボルはプログラム全体で番号を振る。メソッドの呼び出し (SEND / SSEND) は b = シンボルの番号
#   - クラスの定義 (class / module / def / def self.) を読み、メソッド表を作る (継承は親クラスへの輪で表す)
#   - 定数は字句の入れ子で探し、クラスならクラスの即値 (CLASS)、ほかは番号 (GETCONST / SETCONST)
#   - 未対応の命令・pool・未知のグローバル変数は、場所を示して止まる
#
# 変換器の一部として PicoRuby でも走る (isa.rb の注記)。isa.rb / io_map.rb / rite.rb を先に読み込んでおくこと。
module FpgaRom
  class Error < StandardError; end

  WORD_BITS = 48
  HEX_DIGITS = WORD_BITS / 4
  # ROM の空き。op 0xff は未対応命令なので、プログラムの外へ出たコアはエラーで止まる。メソッド表の空きも同じ
  PAD = (1 << WORD_BITS) - 1

  class Word
    attr_reader :pc, :insn, :op, :a, :b, :c, :irep, :first

    # first: 元の命令を展開した語のうち先頭か (block_given? は1命令が数語になる)。
    # insn が nil の語は変換器が足したもの (TABLE、クラスの本体の先頭の ENTER、メソッド表)
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
    attr_accessor :symbols # シンボルの名前 (番号順)
    attr_accessor :table_base, :table_size
    attr_accessor :class_names # クラスの番号 -> 名前 (ユーザーのクラスとモジュール)

    def initialize(words, nregs, ireps)
      @words = words
      @nregs = nregs
      @ireps = ireps
      @symbols = []
      @table_base = 0
      @table_size = 0
      @class_names = {}
    end

    def hex
      out = ""
      words.each { |w| out << w.hex << "\n" }
      out
    end

    # 人が読む一覧。irep ごとに見出しを付け、pc と元の iseq のバイト位置を並べる。最後にメソッド表とシンボル
    def listing
      out = ""
      words.each do |w|
        if w.pc >= table_base && table_size > 0
          next if w.value == PAD
          out << "# method table (#{table_size} words)\n" if out.index("# method table").nil?
          cls = (w.op << 8) | w.a
          kind = w.c >> 14
          tgt = w.c & 0x3FFF
          isa = (cls & FpgaIsa::ISA_BIT) != 0
          what = if w.b == FpgaIsa::SUPER_SYM then "super #{w.c}"
                 elsif w.b == FpgaIsa::NIVARS_SYM then "ivars #{w.c}"
                 elsif isa then "is_a"
                 elsif kind == FpgaIsa::TGT_PRIM then "prim #{FpgaIsa::PRIMS[tgt] ? FpgaIsa::PRIMS[tgt][3] : tgt}"
                 elsif kind == FpgaIsa::TGT_IVAR then "ivar #{tgt}"
                 elsif kind == FpgaIsa::TGT_IVSET then "ivar= #{tgt}"
                 else "pc #{tgt}"
                 end
          sym = if w.b == FpgaIsa::SUPER_SYM || w.b == FpgaIsa::NIVARS_SYM then "-"
                elsif isa then "class #{w.b}"
                else ":#{symbols[w.b]}"
                end
          out << format("%4d  class %-5d %-18s %s\n", w.pc, cls, sym, what)
          next
        end
        ir = w.irep
        out << format("# irep %d  nregs %d\n", ir.index, ir.nregs) if ir && w.pc == ir.base
        name = FpgaIsa::OPS[w.op].name
        from = w.insn.nil? ? "  (added)" : name == w.insn.name ? "" : "  <- #{w.insn.name}"
        addr = w.insn && w.first ? format("%03d", w.insn.addr) : "   "
        out << format("%4d  %s  %-9s a=%-3d b=%-5d c=%-5d  %s%s\n", w.pc, addr, name, w.a, w.b, w.c, w.hex, from)
      end
      unless class_names.empty?
        out << "# classes\n"
        class_names.keys.sort.each { |id| out << format("%4d  %s\n", id, class_names[id]) }
      end
      unless symbols.empty?
        out << "# symbols\n"
        symbols.each_with_index { |s, i| out << format("%4d  :%s\n", i, s) }
      end
      out
    end
  end

  # クラスとモジュール。methods / meta_methods はメソッド名 -> 中身の irep。
  # super_id はメソッド探索の親 (include した iclass を含む)、real_super_id は本当の親クラス。
  # ivar_names は自分のメソッドに出るインスタンス変数、attrs は attr_* (名前 -> "r" / "w" / "rw")、
  # includes は include したモジュール、origin は iclass の元のモジュール
  class Klass
    attr_reader :name, :id, :methods, :meta_methods, :is_module, :ivar_names, :attrs, :includes, :cvars
    attr_accessor :super_id, :real_super_id, :origin, :owner

    def initialize(name, id, super_id, is_module)
      @name = name
      @id = id
      @super_id = super_id
      @real_super_id = super_id
      @is_module = is_module
      @methods = {}
      @meta_methods = {}
      @ivar_names = []
      @attrs = {}
      @includes = []
      @cvars = []
      @origin = nil
    end

    def add_ivar(name)
      @ivar_names << name unless @ivar_names.include?(name)
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

    ctx = Context.new(source, decoded)
    analyze(top, ctx.object, ctx)
    add_iclasses(ctx)

    # 1命令が何語になるかを数えて、irep と命令の先頭 pc を決める。pc 0 は TABLE、クラスの本体は先頭に ENTER を足し、
    # 一番外は先頭で self (main) を作る (CLASS R0 Object、SEND R0 :new)
    base = 1
    pc_of = []
    ireps.each_with_index do |ir, i|
      ir.base = base
      base += 1 if ctx.bodies[ir.index]
      base += 2 if ir.index == 0
      table = {}
      decoded[i].each_with_index do |insn, k|
        table[insn.addr] = base
        specs = lowered(insn, ir, k, base, ctx)
        base += specs ? specs.size : 1
      end
      pc_of << table
    end

    words = [nil]
    ireps.each_with_index do |ir, i|
      words << Word.new(ir.base, nil, FpgaIsa.op("ENTER").num, 0, ir.nregs, 0, ir, false) if ctx.bodies[ir.index]
      if ir.index == 0
        words << Word.new(ir.base, nil, FpgaIsa.op("CLASS").num, 0, FpgaIsa::CLS_OBJECT, 0, ir, false)
        words << Word.new(ir.base + 1, nil, FpgaIsa.op("SEND0").num, 0, ctx.sym_id("new"), 0, ir, false)
      end
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

    entries = method_entries(ctx)
    size = 16
    size *= 2 while size < entries.size * 2
    log2 = 0
    log2 += 1 while (1 << log2) < size
    tbase = words.size
    if tbase + size > (1 << FpgaIsa::PC_BITS)
      raise Error, "#{source}: the program and its method table need #{tbase + size} words, the ROM has #{1 << FpgaIsa::PC_BITS}"
    end
    slots = Array.new(size)
    entries.each do |cls, sym, tgt|
      h = FpgaIsa.table_hash(cls, sym, size - 1)
      h = (h + 1) & (size - 1) while slots[h]
      slots[h] = [cls, sym, tgt]
    end
    words[0] = Word.new(0, nil, FpgaIsa.op("TABLE").num, log2, tbase, 0, top, false)
    slots.each_with_index do |e, i|
      words << if e
                 Word.new(tbase + i, nil, e[0] >> 8, e[0] & 0xFF, e[1], e[2], nil, false)
               else
                 Word.new(tbase + i, nil, 0xFF, 0xFF, 0xFFFF, 0xFFFF, nil, false)
               end
    end

    image = Image.new(words, top.nregs, ireps)
    image.symbols = ctx.symbols.keys
    image.table_base = tbase
    image.table_size = size
    ctx.classes.each { |k| image.class_names[k.id] = k.name if k.id >= FpgaIsa::FIRST_USER_CLASS }
    image
  end

  # 変換中に持ち回るもの
  #   classes: 全クラス (組み込み + プログラムの)。scope: irep の番号 -> 字句のクラス (定数と def の持ち主)
  #   bodies: クラスの本体の irep の番号 -> true。parents: ブロックの irep の番号 -> 作った irep
  #   class_at / exec_at: CLASS / EXEC の場所 -> クラス / 本体の irep。consts: 定数の名前 (字句の path) -> 番号
  class Context
    attr_reader :source, :decoded, :classes, :scope, :bodies, :parents, :class_at, :exec_at, :consts, :const_keys,
                :method_names, :noops
    attr_accessor :lambdas # lambda にするブロックの irep の番号 -> true
    attr_accessor :symbols # シンボルの名前 -> 番号 (出てきた順)

    def initialize(source, decoded)
      @source = source
      @decoded = decoded
      @classes = []
      FpgaIsa::CLASSES.each do |name, id|
        sup = { "Object" => nil, "Class" => FpgaIsa.class_id("Module") }.fetch(name, FpgaIsa::CLS_OBJECT)
        @classes << Klass.new(name, id, sup, name == "Module" ? false : false)
      end
      @method_names = {} # メソッドの irep の番号 -> 名前 (super が使う)
      @noops = {}        # クラスの本体の attr_* / include / private など (実行時は何もしない) の場所 -> true
      @scope = {}
      @bodies = {}
      @parents = {}
      @class_at = {}
      @exec_at = {}
      @consts = {}
      @const_keys = {}
      @lambdas = {}
      @symbols = {}
      FpgaIsa::OP_SYMS.each { |s| sym_id(s) } # 演算の落ち先は固定の番号
    end

    def sym_id(name)
      @symbols[name] = @symbols.size unless @symbols.key?(name)
      @symbols[name]
    end

    def object
      @classes[0]
    end

    def klass_named(name)
      @classes.each { |k| return k if k.name == name }
      nil
    end

    def klass_id(id)
      @classes.each { |k| return k if k.id == id }
      nil
    end

    def next_id
      id = FpgaIsa::FIRST_USER_CLASS
      @classes.each { |k| id = k.id + 1 if k.id >= id }
      id
    end

    # 字句の入れ子 (A::B の中なら A::B, A, 一番外) の順に、名前の候補
    def lexical_names(scope, name)
      names = []
      path = scope.id == FpgaIsa::CLS_OBJECT ? "" : scope.name
      while path != ""
        names << "#{path}::#{name}"
        cut = path.rindex("::")
        path = cut ? path[0, cut] : ""
      end
      names << name
      names
    end
  end

  def self.site_key(irep, k)
    "#{irep.index}:#{k}"
  end

  # k 番目の命令より前で、最後に R[reg] を書いた命令 (a に書く命令だけを見る)
  def self.prev_def(insns, k, reg)
    i = k - 1
    while i >= 0
      insn = insns[i]
      return insn if insn.operands[0] == reg && !%w[SETGV SETCONST SETIV JMP JMPIF JMPNOT JMPNIL].include?(insn.name)
      i -= 1
    end
    nil
  end

  # irep を字句のクラス scope の中として読み、クラス・メソッド・定数・ブロックの親を集める
  def self.analyze(irep, scope, ctx)
    source = ctx.source
    ctx.scope[irep.index] = scope
    insns = ctx.decoded[irep.index]
    insns.each_with_index do |insn, k|
      ops = insn.operands
      case insn.name
      when "CLASS", "MODULE"
        a = ops[0]
        sym = irep.syms[ops[1]]
        outer = prev_def(insns, k, a)
        unless outer && outer.name == "LOADNIL"
          raise Error, "#{source}: #{insn.name.downcase} #{sym} at #{where(irep, insn)} is nested with ::, which is not supported"
        end
        super_id = nil
        if insn.name == "CLASS"
          sup = prev_def(insns, k, a + 1)
          if sup && sup.name == "GETCONST"
            sname = irep.syms[sup.operands[1]]
            sk = nil
            ctx.lexical_names(scope, sname).each { |n| sk ||= ctx.klass_named(n) }
            raise Error, "#{source}: superclass #{sname} of #{sym} at #{where(irep, insn)} is not a known class" unless sk
            super_id = sk.id
          elsif !(sup && sup.name == "LOADNIL")
            raise Error, "#{source}: the superclass of #{sym} at #{where(irep, insn)} must be a constant"
          end
        end
        full = scope.id == FpgaIsa::CLS_OBJECT ? sym : "#{scope.name}::#{sym}"
        k2 = ctx.klass_named(full)
        if k2
          if super_id && k2.super_id != super_id
            raise Error, "#{source}: superclass mismatch for #{full} at #{where(irep, insn)}"
          end
        else
          k2 = Klass.new(full, ctx.next_id, insn.name == "CLASS" ? (super_id || FpgaIsa::CLS_OBJECT) : nil, insn.name == "MODULE")
          ctx.classes << k2
        end
        ctx.class_at[site_key(irep, k)] = k2
        # 続く EXEC a I[n] が本体
        j = k + 1
        while j < insns.size && !(insns[j].name == "EXEC" && insns[j].operands[0] == a)
          j += 1
        end
        raise Error, "#{source}: no body for #{full} at #{where(irep, insn)}" if j >= insns.size
        body = irep.reps[insns[j].operands[1]]
        ctx.exec_at[site_key(irep, j)] = body
        ctx.bodies[body.index] = true
        analyze(body, k2, ctx)
      when "TDEF"
        m = irep.reps[ops[2]]
        scope.methods[irep.syms[ops[1]]] = m # 後の定義が勝つ (静的に決める)
        ctx.method_names[m.index] = irep.syms[ops[1]]
        analyze(m, scope, ctx)
      when "SDEF"
        d = prev_def(insns, k, ops[0])
        unless ctx.bodies[irep.index] && d && d.name == "LOADSELF"
          raise Error, "#{source}: def of a singleton method at #{where(irep, insn)} is only supported as `def self.x` in a class body"
        end
        m = irep.reps[ops[2]]
        scope.meta_methods[irep.syms[ops[1]]] = m
        ctx.method_names[m.index] = irep.syms[ops[1]]
        analyze(m, scope, ctx)
      when "BLOCK", "LAMBDA"
        block = irep.reps[ops[1]]
        ctx.parents[block.index] = irep
        ctx.lambdas[block.index] = true if insn.name == "LAMBDA"
        block_params(block, ctx.decoded[block.index], source)
        analyze(block, scope, ctx)
      when "SETCONST"
        name = irep.syms[ops[1]]
        ctx.const_keys[scope.id == FpgaIsa::CLS_OBJECT ? name : "#{scope.name}::#{name}"] = true
      when "SSENDB"
        # lambda { } に渡したブロックは lambda (ブロックの中の return を通すため)
        sym = irep.syms[ops[1]]
        prev = k > 0 ? insns[k - 1] : nil
        argc = ops[2] & 0xF
        if sym == "lambda" && prev && prev.name == "BLOCK" && prev.operands[0] == ops[0] + argc + 1
          ctx.lambdas[irep.reps[prev.operands[1]].index] = true
        end
      when "SSEND", "SSEND0"
        sym = irep.syms[ops[1]]
        next unless ctx.bodies[irep.index]
        argc = insn.name == "SSEND0" ? 0 : ops[2] & 0xF
        case sym
        when "attr_reader", "attr_writer", "attr_accessor"
          argc.times do |j|
            d = prev_def(insns, k, ops[0] + 1 + j)
            raise Error, "#{source}: #{sym} at #{where(irep, insn)} takes symbols only" unless d && d.name == "LOADSYM"
            name = irep.syms[d.operands[1]]
            mode = { "attr_reader" => "r", "attr_writer" => "w", "attr_accessor" => "rw" }[sym]
            scope.attrs[name] = ((scope.attrs[name] || "") + mode)
            scope.add_ivar("@#{name}")
          end
          ctx.noops[site_key(irep, k)] = true
        when "include"
          argc.times do |j|
            d = prev_def(insns, k, ops[0] + 1 + j)
            raise Error, "#{source}: include at #{where(irep, insn)} takes module constants only" unless d && d.name == "GETCONST"
            mname = irep.syms[d.operands[1]]
            mod = nil
            ctx.lexical_names(scope, mname).each { |n| mod ||= ctx.klass_named(n) }
            raise Error, "#{source}: #{mname} at #{where(irep, insn)} is not a known module" unless mod && mod.is_module
            scope.includes << mod
          end
          ctx.noops[site_key(irep, k)] = true
        when "private", "public", "protected", "module_function"
          ctx.noops[site_key(irep, k)] = true # 見え方は区別しない
        when "extend", "prepend", "define_method", "alias_method"
          raise Error, "#{source}: #{sym} in a class body at #{where(irep, insn)} is not supported"
        end
      when "GETIV", "SETIV"
        name = irep.syms[ops[1]]
        if ctx.bodies[irep.index]
          raise Error, "#{source}: #{name} in a class body at #{where(irep, insn)} (class-level instance variables are not supported)"
        end
        scope.add_ivar(name)
      when "SETCV"
        scope.cvars << irep.syms[ops[1]] unless scope.cvars.include?(irep.syms[ops[1]])
      when "SUPER"
        raise Error, "#{source}: super inside a block at #{where(irep, insn)} is not supported" if ctx.parents[irep.index]
        raise Error, "#{source}: super outside a method at #{where(irep, insn)}" unless ctx.method_names[irep.index]
      end
    end
  end

  # include したモジュールごとに iclass を作り、探索の親の輪を C -> iclass (後に include したものが先) -> 元の親 にする
  def self.add_iclasses(ctx)
    ctx.classes.dup.each do |k|
      next if k.includes.empty?
      prev = k.super_id
      k.includes.each do |mod|
        ic = Klass.new("#{k.name}(#{mod.name})", ctx.next_id, prev, false)
        ic.origin = mod
        ic.owner = k
        ic.real_super_id = nil
        mod.methods.each { |name, m| ic.methods[name] = m }
        ctx.classes << ic
        prev = ic.id
      end
      k.super_id = prev
    end
  end

  # クラスのインスタンス変数の並び (親クラスの分、自分の分、include したモジュールの分)
  def self.ivar_layout(ctx, k)
    return [] unless k
    layout = ivar_layout(ctx, k.real_super_id ? ctx.klass_id(k.real_super_id) : nil).dup
    k.ivar_names.each { |n| layout << n unless layout.include?(n) }
    k.includes.each { |mod| mod.ivar_names.each { |n| layout << n unless layout.include?(n) } }
    layout
  end

  # クラス変数の持ち主: 本当の親クラスをたどって、一番上でそれを代入するクラス (無ければ自分)
  def self.cvar_owner(ctx, k, name)
    owner = k
    cur = k
    while cur
      owner = cur if cur.cvars.include?(name)
      cur = cur.real_super_id ? ctx.klass_id(cur.real_super_id) : nil
    end
    owner
  end

  # 祖先 (探索の親をたどる。iclass は元のモジュール)
  def self.ancestors(ctx, k)
    list = []
    cur = k
    while cur
      list << (cur.origin ? cur.origin.id : cur.id)
      cur = cur.super_id ? ctx.klass_id(cur.super_id) : nil
    end
    list
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

  # 誰も def していない名前か (block_given? を下げてよいか)
  def self.defined_anywhere?(ctx, sym)
    ctx.classes.each { |k| return true if k.methods[sym] || k.meta_methods[sym] }
    false
  end

  # ほかの命令の列に下げる命令なら [[名前, a, b, c], ...] を返す。そのまま1語にするなら nil
  def self.lowered(insn, ir, k, pc, ctx)
    if (insn.name == "SSEND0" || insn.name == "SSEND") && ir.syms[insn.operands[1]] == "block_given?" &&
       !defined_anywhere?(ctx, "block_given?")
      # block_given? は、囲むメソッドのブロックの枠 (必須の引数の次) を BLKPUSH で読み、!! で true / false にする
      depth, method = block_depth(ir, ctx)
      m1 = method.index == 0 ? 0 : block_params(method, ctx.decoded[method.index], ctx.source)
      a = insn.operands[0]
      bang = ctx.sym_id("!")
      return [["BLKPUSH", a, m1 + 1, depth], ["SEND0", a, bang, 0], ["SEND0", a, bang, 0]]
    end
    return [["LOADTRUE", 0, 0, 0], ["RETURN", 0, 0, 0]] if insn.name == "RETTRUE"
    return [["LOADFALSE", 0, 0, 0], ["RETURN", 0, 0, 0]] if insn.name == "RETFALSE"
    nil
  end

  # メソッド表の中身: [クラス, シンボル, 飛び先] の列
  def self.method_entries(ctx)
    entries = []
    ctx.classes.each do |k|
      k.methods.each { |sym, m| entries << [k.id, ctx.sym_id(sym), m.base] }
      k.meta_methods.each { |sym, m| entries << [FpgaIsa::META | k.id, ctx.sym_id(sym), m.base] }
    end
    # primitive: その名前がプログラムのどこかに出てくるものだけ (出ないものは呼べない)。同じクラスの def が勝つ
    FpgaIsa::PRIMS.each_with_index do |pr, i|
      next unless ctx.symbols.key?(pr[1])
      k = ctx.klass_named(pr[0])
      next if k.methods[pr[1]]
      entries << [k.id, ctx.symbols[pr[1]], (FpgaIsa::TGT_PRIM << 14) | i]
    end
    # 親クラスへの輪。メタクラスは本当の親のメタクラスへ、Object のメタクラスは Class へ
    ctx.classes.each do |k|
      if k.is_module # モジュールのメタクラスの親は Module
        entries << [FpgaIsa::META | k.id, FpgaIsa::SUPER_SYM, FpgaIsa.class_id("Module")]
        next
      end
      entries << [k.id, FpgaIsa::SUPER_SYM, k.super_id] if k.super_id
      next if k.origin # iclass にメタクラスは無い
      entries << [FpgaIsa::META | k.id, FpgaIsa::SUPER_SYM, k.real_super_id ? FpgaIsa::META | k.real_super_id : FpgaIsa::CLS_CLASS]
    end
    # インスタンス変数: 自分で増やした分 (親の分は親の項目で見つかる)、iclass はモジュールの分、attr_*、new が使う数
    ctx.classes.each do |k|
      next if k.is_module
      if k.origin
        layout = ivar_layout(ctx, k.owner) # include したクラスの並びでの番号
        (k.origin.ivar_names + k.origin.attrs.keys.map { |a| "@#{a}" }).uniq.each do |n|
          entries << [k.id, ctx.sym_id(n), (FpgaIsa::TGT_IVAR << 14) | layout.index(n)] if layout.index(n)
        end
        attr_entries(ctx, k, k.origin.attrs, layout, entries)
        next
      end
      layout = ivar_layout(ctx, k)
      parent = ivar_layout(ctx, k.real_super_id ? ctx.klass_id(k.real_super_id) : nil)
      (layout - parent).each { |n| entries << [k.id, ctx.sym_id(n), (FpgaIsa::TGT_IVAR << 14) | layout.index(n)] }
      attr_entries(ctx, k, k.attrs, layout, entries)
      entries << [k.id, FpgaIsa::NIVARS_SYM, layout.size] unless layout.empty?
    end
    # is_a? / kind_of? / === (祖先ごとに1語。名前が出てくる時だけ)
    if %w[is_a? kind_of? ===].any? { |n| ctx.symbols.key?(n) }
      ctx.classes.each do |k|
        next if k.is_module || k.origin
        ancestors(ctx, k).uniq.each { |a| entries << [FpgaIsa::ISA_BIT | k.id, a, 1] }
        meta = []
        cur = k
        while cur
          meta << (FpgaIsa::META | cur.id)
          cur = cur.real_super_id ? ctx.klass_id(cur.real_super_id) : nil
        end
        (meta + [FpgaIsa::CLS_CLASS, FpgaIsa.class_id("Module"), FpgaIsa::CLS_OBJECT]).each do |a|
          entries << [FpgaIsa::ISA_BIT | FpgaIsa::META | k.id, a, 1]
        end
      end
    end
    entries
  end

  def self.attr_entries(ctx, k, attrs, layout, entries)
    attrs.each do |name, mode|
      slot = layout.index("@#{name}")
      next unless slot
      entries << [k.id, ctx.sym_id(name), (FpgaIsa::TGT_IVAR << 14) | slot] if mode.include?("r")
      entries << [k.id, ctx.sym_id("#{name}="), (FpgaIsa::TGT_IVSET << 14) | slot] if mode.include?("w")
    end
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

    # クラス変数: 持ち主のクラスごとの定数と同じ番号にする
    if name == "GETCV" || name == "SETCV"
      owner = cvar_owner(ctx, ctx.scope[irep.index], irep.syms[b])
      key = "#{owner.name}::#{irep.syms[b]}"
      slot = ctx.consts[key]
      unless slot
        slot = ctx.consts.size
        raise Error, "#{source}: too many constants (the core has #{FpgaIsa::NCONST}) at #{irep.syms[b]}" if slot >= FpgaIsa::NCONST
        ctx.consts[key] = slot
      end
      return Word.new(pc, insn, FpgaIsa.op(name == "GETCV" ? "GETCONST" : "SETCONST").num, a, slot, 0, irep)
    end

    # インスタンス変数: b = @名前 のシンボルの番号 (実行時に self のクラスで番号を引く)
    b = ctx.sym_id(irep.syms[ops[1]]) if name == "GETIV" || name == "SETIV"

    # super: b = 今のメソッドの名前、c = 引数の数 | ブロックの枠を渡す印 (いつも)
    if name == "SUPER"
      argc = ops[1] & 0xF
      raise Error, "#{source}: super at #{where(irep, insn)} with keyword arguments or a splat is not supported yet" if (ops[1] >> 4) != 0 || argc == 15
      return Word.new(pc, insn, insn.op.num, a, ctx.sym_id(ctx.method_names[irep.index]), argc | 0x80, irep)
    end

    # クラスの本体の attr_* / include / private など: 実行時は nil を置くだけ
    return Word.new(pc, insn, FpgaIsa.op("LOADNIL").num, a, 0, 0, irep) if ctx.noops[site_key(irep, k)]

    # 定数: 字句の入れ子の順に探す。クラスならその即値 (CLASS)、ほかは番号
    if name == "GETCONST" || name == "SETCONST"
      sym = irep.syms[b]
      scope = ctx.scope[irep.index]
      key = nil
      if name == "SETCONST"
        key = scope.id == FpgaIsa::CLS_OBJECT ? sym : "#{scope.name}::#{sym}"
      else
        ctx.lexical_names(scope, sym).each do |n|
          next if key
          kl = ctx.klass_named(n)
          return Word.new(pc, insn, FpgaIsa.op("CLASS").num, a, kl.id, 0, irep) if kl
          key = n if ctx.const_keys[n]
        end
        key ||= sym
      end
      slot = ctx.consts[key]
      unless slot
        slot = ctx.consts.size
        raise Error, "#{source}: too many constants (the core has #{FpgaIsa::NCONST}) at #{sym}" if slot >= FpgaIsa::NCONST
        ctx.consts[key] = slot
      end
      b = slot
    end

    # クラス / モジュール: R[a] = クラスの即値。本体 (EXEC): b = 本体の先頭 pc
    return Word.new(pc, insn, FpgaIsa.op("CLASS").num, a, ctx.class_at[site_key(irep, k)].id, 0, irep) if name == "CLASS" || name == "MODULE"
    return Word.new(pc, insn, FpgaIsa.op("EXEC").num, a, ctx.exec_at[site_key(irep, k)].base, 0, irep) if name == "EXEC"

    # def: メソッド表は変換時に作ったので、実行時は R[a] = :名前 だけ
    if name == "TDEF" || name == "SDEF"
      b = ctx.sym_id(irep.syms[ops[1]])
      c = 0
    end

    return Word.new(pc, insn, FpgaIsa.op("MOVE").num, a, 0, 0, irep) if name == "LOADSELF"
    return Word.new(pc, insn, FpgaIsa.op("RETURN").num, 0, 0, 0, irep) if name == "RETSELF"

    # メソッドの呼び出し: b = シンボルの番号、c = 引数の数 | ブロックを渡す印 << 7。SSEND は self に送る
    if %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(name)
      sym = irep.syms[ops[1]]
      argc = name.end_with?("0") ? 0 : ops[2] & 0xF
      kw = name.end_with?("0") ? 0 : ops[2] >> 4
      if kw != 0 || argc == 15
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with keyword arguments or a splat (not supported yet)"
      end
      blk = name.end_with?("B")
      op = name.start_with?("SS") ? (blk ? "SSEND" : name) : (blk ? "SEND" : name)
      return Word.new(pc, insn, FpgaIsa.op(op).num, a, ctx.sym_id(sym), argc | (blk ? 0x80 : 0), irep)
    end

    # ENTER: 必須の引数 (と &blk) だけ。a = 必須の引数の数、b = nregs (ENTER が残りのレジスタを nil で埋める)、
    # c = &blk を受けるか。ブロックの ENTER は NOP にする (Proc は BLKCALL が埋め、引数の数は lambda だけ調べる)
    if name == "ENTER"
      aspec = ops[0]
      m1 = (aspec >> 18) & 0x1F
      if (aspec & ~((0x1F << 18) | 1)) != 0
        raise Error, "#{source}: method at #{where(irep, insn)} takes optional, rest or keyword parameters " \
                     "(only required parameters and &block are supported)"
      end
      return Word.new(pc, insn, FpgaIsa.op("NOP").num, 0, 0, 0, irep) if ctx.parents[irep.index]
      a = m1
      b = irep.nregs
      c = aspec & 1
    end

    # LOADSYM: b = プログラム全体で振ったシンボルの番号
    b = ctx.sym_id(irep.syms[ops[1]]) if name == "LOADSYM"

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

    # BREAK: Proc を作ったフレームまで畳み、その呼び出しの結果にする (c = 1。c = 0 はフレームを1つ畳んで b へ)
    if name == "BREAK"
      raise Error, "#{source}: break at #{where(irep, insn)} is not inside a block" unless ctx.parents[irep.index]
      b = 0
      c = 1
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
