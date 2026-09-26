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
    attr_accessor :data_base, :symtab # 文字列とシンボルの名前のデータの先頭、シンボル表の先頭 (その間がデータ)
    attr_accessor :class_names # クラスの番号 -> 名前 (ユーザーのクラスとモジュール)

    def initialize(words, nregs, ireps)
      @words = words
      @nregs = nregs
      @ireps = ireps
      @symbols = []
      @table_base = 0
      @table_size = 0
      @data_base = 0
      @symtab = 0
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
        if w.pc >= data_base && w.pc < table_base && data_base > 0
          # データ (1語 4バイト) とシンボル表
          if w.pc < symtab
            out << "# data (strings and symbol names, 4 bytes per word)\n" if w.pc == data_base
            text = ""
            4.times do |j|
              x = (w.value >> (8 * j)) & 0xFF
              text << (x >= 0x20 && x < 0x7F ? x.chr : ".")
            end
            out << format("%4d  %s  %s\n", w.pc, w.hex, text)
          else
            out << "# symbol table (address, length)\n" if w.pc == symtab
            out << format("%4d  %-5d %-5d :%s\n", w.pc, w.b, w.c, symbols[w.pc - symtab])
          end
          next
        end
        if w.pc >= table_base && table_size > 0
          next if w.value == PAD
          out << "# method table (#{table_size} words)\n" if out.index("# method table").nil?
          cls = (w.op << 8) | w.a
          kind = w.c >> 14
          tgt = w.c & 0x3FFF
          isa = (cls & FpgaIsa::ISA_BIT) != 0
          what = if w.b == FpgaIsa::SUPER_SYM then "super #{w.c}"
                 elsif w.b == FpgaIsa::NIVARS_SYM then "ivars #{w.c}"
                 elsif w.b == FpgaIsa::NAME_SYM then "name :#{symbols[w.c]}"
                 elsif isa then "is_a"
                 elsif kind == FpgaIsa::TGT_PRIM then "prim #{FpgaIsa::PRIMS[tgt] ? FpgaIsa::PRIMS[tgt][3] : tgt}"
                 elsif kind == FpgaIsa::TGT_IVAR then "ivar #{tgt}"
                 elsif kind == FpgaIsa::TGT_IVSET then "ivar= #{tgt}"
                 else "pc #{tgt}"
                 end
          sym = if w.b == FpgaIsa::SUPER_SYM || w.b == FpgaIsa::NIVARS_SYM || w.b == FpgaIsa::NAME_SYM then "-"
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
      raise Error, "#{source}: irep #{ir.index} has catch handlers (exceptions are not supported)" if ir.clen > 0
      if max_regs && ir.nregs > max_regs
        raise Error, "#{source}: irep #{ir.index} needs #{ir.nregs} registers, the core has #{max_regs}"
      end
      decoded << Rite.decode(ir.iseq)
    end

    bad = []
    ctx = Context.new(source, decoded)
    analyze(top, ctx.object, ctx)
    add_iclasses(ctx)
    # 呼ばれることのあるメソッドだけを ROM に置く (プレリュードの使わないメソッドを落とす)
    ctx.live = live_ireps(ireps, decoded, ctx)

    ireps.each_with_index do |ir, i|
      next unless ctx.live[i]
      decoded[i].each { |insn| bad << "#{insn.name} at #{where(ir, insn)}" unless FpgaIsa.convertible?(insn.name) }
    end
    raise Error, "#{source}: unsupported instruction(s): #{bad.join(', ')}" unless bad.empty?

    # pool: 文字列は ROM のデータ領域に置く (同じ中身は1つ)。整数は 32bit に収まること。Float と大きい整数は止める
    ireps.each_with_index do |ir, i|
      next unless ctx.live[i]
      decoded[i].each do |insn|
        next unless insn.name == "STRING" || insn.name == "LOADL"
        e = ir.pool[insn.operands[1]]
        raise Error, "#{source}: #{insn.name} at #{where(ir, insn)} refers to a missing pool entry" unless e
        if insn.name == "STRING"
          raise Error, "#{source}: STRING at #{where(ir, insn)} refers to a non-string pool entry" unless e[0] == :str
          ctx.add_string(e[1])
        elsif e[0] != :int
          raise Error, "#{source}: LOADL at #{where(ir, insn)} loads a #{e[0] == :float ? 'Float' : (e[0] == :bigint ? 'big integer' : 'non-integer')} (not supported)"
        elsif e[1] < -0x8000_0000 || e[1] > 0x7FFF_FFFF
          raise Error, "#{source}: LOADL at #{where(ir, insn)} loads #{e[1]}, which does not fit in 32 bits"
        end
      end
    end

    # 1命令が何語になるかを数えて、irep と命令の先頭 pc を決める。pc 0 は TABLE、クラスの本体は先頭に ENTER を足し、
    # 一番外は先頭で self (main) を作る (CLASS R0 Object、SEND R0 :new)
    base = 1
    pc_of = []
    ireps.each_with_index do |ir, i|
      unless ctx.live[i]
        ir.base = nil
        pc_of << {}
        next
      end
      ir.base = base
      base += 1 if ctx.bodies[ir.index]
      base += 2 + 2 * ctx.globals.size if ir.index == 0
      table = {}
      decoded[i].each_with_index do |insn, k|
        table[insn.addr] = base
        specs = lowered(insn, ir, k, base, ctx)
        base += specs ? specs.size : 1
      end
      pc_of << table
    end
    # 文字列のデータ (1語 4バイト) はプログラムの後ろ
    data_base = base
    ctx.place_strings(data_base)

    words = [nil]
    ireps.each_with_index do |ir, i|
      next unless ctx.live[i]
      words << Word.new(ir.base, nil, FpgaIsa.op("ENTER").num, 0, ir.nregs, 0, ir, false) if ctx.bodies[ir.index]
      if ir.index == 0
        # 一般のグローバル変数を nil に (R0 を借りる)、self (main) を作る
        ctx.globals.each_with_index do |g, j|
          words << Word.new(ir.base + 2 * j, nil, FpgaIsa.op("LOADNIL").num, 0, 0, 0, ir, false)
          words << Word.new(ir.base + 2 * j + 1, nil, FpgaIsa.op("SETCONST").num, 0, ctx.consts.fetch(g), 0, ir, false)
        end
        g = 2 * ctx.globals.size
        words << Word.new(ir.base + g, nil, FpgaIsa.op("CLASS").num, 0, FpgaIsa::CLS_OBJECT, 0, ir, false)
        words << Word.new(ir.base + g + 1, nil, FpgaIsa.op("SEND0").num, 0, ctx.sym_id("new"), 0, ir, false)
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

    ctx.strings.each { |str| words.concat(data_words(str, ctx.string_at[str])) }

    entries = method_entries(ctx)
    # シンボルの名前 (データ) と、シンボル表 (番号 -> {データの語アドレス, 長さ})。Symbol#to_s が使う
    names = ctx.symbols.keys
    sym_addr = []
    names.each do |n|
      sym_addr << words.size
      words.concat(data_words(n.to_s, words.size))
    end
    symtab = words.size
    names.each_with_index { |n, i| words << Word.new(symtab + i, nil, 0, 0, sym_addr[i], n.to_s.bytesize, nil, false) }
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
    words[0] = Word.new(0, nil, FpgaIsa.op("TABLE").num, log2, tbase, symtab, top, false)
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
    image.data_base = data_base
    image.symtab = symtab
    ctx.classes.each { |k| image.class_names[k.id] = k.name if k.id >= FpgaIsa::FIRST_USER_CLASS }
    image
  end

  # 変換中に持ち回るもの
  #   classes: 全クラス (組み込み + プログラムの)。scope: irep の番号 -> 字句のクラス (定数と def の持ち主)
  #   bodies: クラスの本体の irep の番号 -> true。parents: ブロックの irep の番号 -> 作った irep
  #   class_at / exec_at: CLASS / EXEC の場所 -> クラス / 本体の irep。consts: 定数の名前 (字句の path) -> 番号
  class Context
    attr_reader :source, :decoded, :classes, :scope, :bodies, :parents, :class_at, :exec_at, :consts, :const_keys,
                :method_names, :noops, :cref, :globals, :strings, :string_at
    attr_accessor :live # irep の番号 -> ROM に置くか (live_ireps)
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
      @cref = {}         # irep の番号 -> 字句の入れ子のクラスの名前 (内側から。一番外は含めない)。Ruby の cref
      @globals = []      # ポートでないグローバル変数の名前 (定数の表に置き、始めに nil にする)
      @strings = []      # pool の文字列 (同じ中身は1つ、出てきた順)
      @string_at = {}    # 文字列 -> データの語アドレス
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

    # 字句の入れ子 (cref: module A; class B の中なら A::B, A、class A::B の中なら A::B だけ) の順に、名前の候補。最後は一番外
    def lexical_names(cref, name)
      cref.map { |c| "#{c}::#{name}" } + [name]
    end

    def add_string(str)
      @strings << str unless @strings.include?(str)
    end

    # 文字列のデータの語アドレスを base から順に決める (1語 4バイト)
    def place_strings(base)
      @strings.each do |str|
        @string_at[str] = base
        base += (str.bytesize + 3) / 4
      end
    end

    # 定数の番号 (無ければ振る)
    def const_slot(key, what)
      unless @consts[key]
        raise Error, "#{@source}: too many constants (the core has #{FpgaIsa::NCONST}) at #{what}" if @consts.size >= FpgaIsa::NCONST
        @consts[key] = @consts.size
      end
      @consts[key]
    end
  end

  # 文字列を 1語 4バイトのデータの語にする (バイト j は bit 8j から)
  def self.data_words(str, addr)
    out = []
    i = 0
    while i < str.bytesize
      v = 0
      4.times { |j| v |= (str.getbyte(i + j) || 0) << (8 * j) }
      out << Word.new(addr + out.size, nil, 0, 0, (v >> 16) & 0xFFFF, v & 0xFFFF, nil, false)
      i += 4
    end
    out
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

  # 生きている irep (ROM に置くもの)。一番外から、生きているコードの中のブロック・クラスの本体と、
  # 名前が使われる (送る、LOADSYM、super、変換器が下げた命令が送る) メソッドを、増えなくなるまでたどる。
  # 演算の落ち先 (OP_SYMS、initialize を含む) はいつも使われる
  def self.live_ireps(ireps, decoded, ctx)
    live = Array.new(ireps.size, false)
    used = {}
    waiting = {} # 名前 -> その名前の、まだ生きていないメソッドの irep の番号
    todo = [0]
    use = lambda do |name|
      unless used[name]
        used[name] = true
        (waiting.delete(name) || []).each { |j| todo << j }
      end
    end
    FpgaIsa::OP_SYMS.each { |s| use.call(s) }
    until todo.empty?
      i = todo.pop
      next if live[i]
      live[i] = true
      ir = ireps[i]
      decoded[i].each do |insn|
        ops = insn.operands
        case insn.name
        when "SEND", "SEND0", "SENDB", "SSEND", "SSEND0", "SSENDB", "LOADSYM" then use.call(ir.syms[ops[1]])
        when "SUPER" then use.call(ctx.method_names[ir.index]) if ctx.method_names[ir.index]
        when "STRCAT"
          use.call("to_s")
          use.call("<<")
        when "HASH" then use.call("__to_hash")
        when "HASHADD" then use.call("__add_pairs")
        when "HASHCAT" then use.call("__merge!")
        when "RANGE_INC" then use.call("__range_inc")
        when "RANGE_EXC" then use.call("__range_exc")
        when "EXEC", "BLOCK", "LAMBDA" then todo << ir.reps[ops[1]].index
        when "TDEF", "SDEF"
          m = ir.reps[ops[2]].index
          name = ir.syms[ops[1]]
          if used[name]
            todo << m
          else
            waiting[name] ||= []
            waiting[name] << m
          end
        end
      end
    end
    live
  end

  # k 番目の命令で R[reg] に入っている定数の path (GETCONST / GETMCNST の連なりを字句の入れ子で解く)。
  # 分からなければ nil
  def self.const_path(ctx, irep, insns, k, reg)
    i = k - 1
    i -= 1 while i >= 0 && !(insns[i].operands[0] == reg && !%w[SETGV SETCONST SETMCNST SETIV JMP JMPIF JMPNOT JMPNIL].include?(insns[i].name))
    return nil if i < 0
    d = insns[i]
    sym = irep.syms[d.operands[1]]
    if d.name == "GETCONST"
      ctx.lexical_names(ctx.cref[irep.index], sym).each do |n|
        return n if ctx.klass_named(n) || ctx.const_keys[n]
      end
      return sym
    end
    return nil unless d.name == "GETMCNST"
    base = const_path(ctx, irep, insns, i, d.operands[0])
    base && ctx.klass_named(base) ? "#{base}::#{sym}" : nil
  end

  # irep を字句のクラス scope (cref は字句の入れ子) の中として読み、クラス・メソッド・定数・ブロックの親を集める
  def self.analyze(irep, scope, ctx, cref = [])
    source = ctx.source
    ctx.scope[irep.index] = scope
    ctx.cref[irep.index] = cref
    insns = ctx.decoded[irep.index]
    insns.each_with_index do |insn, k|
      ops = insn.operands
      case insn.name
      when "CLASS", "MODULE"
        a = ops[0]
        sym = irep.syms[ops[1]]
        outer = prev_def(insns, k, a)
        # class A::B: 入れ物は A (知っているクラスかモジュール)。字句の入れ子には A を足さない (Ruby の cref と同じ)
        container = scope.id == FpgaIsa::CLS_OBJECT ? nil : scope.name
        unless outer && outer.name == "LOADNIL"
          path = const_path(ctx, irep, insns, k, a)
          unless path && ctx.klass_named(path)
            raise Error, "#{source}: #{insn.name.downcase} #{sym} at #{where(irep, insn)} is nested in something that is not a known class or module"
          end
          container = path
        end
        super_id = nil
        if insn.name == "CLASS"
          sup = prev_def(insns, k, a + 1)
          if sup && (sup.name == "GETCONST" || sup.name == "GETMCNST")
            sname = const_path(ctx, irep, insns, k, a + 1)
            sk = sname && ctx.klass_named(sname)
            raise Error, "#{source}: superclass #{sname || '?'} of #{sym} at #{where(irep, insn)} is not a known class" unless sk
            super_id = sk.id
          elsif !(sup && sup.name == "LOADNIL")
            raise Error, "#{source}: the superclass of #{sym} at #{where(irep, insn)} must be a constant"
          end
        end
        full = container ? "#{container}::#{sym}" : sym
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
        # すぐ後の EXEC a I[n] が本体 (空の本体 `class E < StandardError; end` には EXEC が無い)
        j = k + 1
        if j < insns.size && insns[j].name == "EXEC" && insns[j].operands[0] == a
          body = irep.reps[insns[j].operands[1]]
          ctx.exec_at[site_key(irep, j)] = body
          ctx.bodies[body.index] = true
          analyze(body, k2, ctx, [full] + cref)
        end
      when "TDEF"
        m = irep.reps[ops[2]]
        scope.methods[irep.syms[ops[1]]] = m # 後の定義が勝つ (静的に決める)
        ctx.method_names[m.index] = irep.syms[ops[1]]
        analyze(m, scope, ctx, cref)
      when "SDEF"
        d = prev_def(insns, k, ops[0])
        unless ctx.bodies[irep.index] && d && d.name == "LOADSELF"
          raise Error, "#{source}: def of a singleton method at #{where(irep, insn)} is only supported as `def self.x` in a class body"
        end
        m = irep.reps[ops[2]]
        scope.meta_methods[irep.syms[ops[1]]] = m
        ctx.method_names[m.index] = irep.syms[ops[1]]
        analyze(m, scope, ctx, cref)
      when "BLOCK", "LAMBDA"
        block = irep.reps[ops[1]]
        ctx.parents[block.index] = irep
        ctx.lambdas[block.index] = true if insn.name == "LAMBDA"
        analyze(block, scope, ctx, cref)
      when "SETCONST"
        name = irep.syms[ops[1]]
        ctx.const_keys[scope.id == FpgaIsa::CLS_OBJECT ? name : "#{scope.name}::#{name}"] = true
      when "SETMCNST"
        # A::X = v: 入れ物 (R[a+1]) は知っているクラスかモジュール
        base = const_path(ctx, irep, insns, k, ops[0] + 1)
        unless base && ctx.klass_named(base)
          raise Error, "#{source}: SETMCNST at #{where(irep, insn)} assigns into something that is not a known class or module"
        end
        ctx.const_keys["#{base}::#{irep.syms[ops[1]]}"] = true
      when "GETGV", "SETGV"
        # io_map.rb に無い名前は一般のグローバル変数 (定数の表に置く)
        name = irep.syms[ops[1]]
        unless FpgaIoMap.fetch(name) || ctx.globals.include?(name)
          ctx.globals << name
          ctx.const_slot(name, name)
        end
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
            ctx.lexical_names(cref, mname).each { |n| mod ||= ctx.klass_named(n) }
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

  # 先頭の ENTER の引数の枠の数 (必須 + 省略可能 + 残り + 後ろの必須)。ブロックの枠はその次
  def self.params_len(insns)
    enter = insns[0]
    return 0 unless enter && enter.name == "ENTER"
    x = enter.operands[0]
    ((x >> 18) & 0x1F) + ((x >> 13) & 0x1F) + ((x >> 12) & 1) + ((x >> 7) & 0x1F)
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
      # block_given? は、囲むメソッドのブロックの枠 (引数の次、R[len+1]) を BLKPUSH で読み、!! で true / false にする
      depth, method = block_depth(ir, ctx)
      len = method.index == 0 ? 0 : params_len(ctx.decoded[method.index])
      a = insn.operands[0]
      bang = ctx.sym_id("!")
      return [["BLKPUSH", a, len + 1, depth], ["SEND0", a, bang, 0], ["SEND0", a, bang, 0]]
    end
    # 式展開: R[a] << R[a+1].to_s (to_s は R[a+1] に、<< の結果 (self) は R[a] に)
    if insn.name == "STRCAT"
      a = insn.operands[0]
      return [["SEND", a + 1, ctx.sym_id("to_s"), 0], ["SEND", a, ctx.sym_id("<<"), 1]]
    end
    # Hash / Range はプレリュードの Ruby のクラス。作る命令はそのメソッドの呼び出しにする
    ops = insn.operands
    case insn.name
    when "HASH" # R[a] = {R[a] => R[a+1], ...} (b 組)
      return [["ARRAY", ops[0], 2 * ops[1], 0], ["SEND", ops[0], ctx.sym_id("__to_hash"), 0]]
    when "HASHADD" # R[a] に R[a+1..] の b 組を足す
      return [["ARRAY", ops[0] + 1, 2 * ops[1], 0], ["SEND", ops[0], ctx.sym_id("__add_pairs"), 1]]
    when "HASHCAT" # R[a] に R[a+1] (Hash) を足す (**h)
      return [["SEND", ops[0], ctx.sym_id("__merge!"), 1]]
    when "RANGE_INC", "RANGE_EXC" # R[a] = R[a]..R[a+1] / R[a]...R[a+1]
      return [["SEND", ops[0], ctx.sym_id(insn.name == "RANGE_INC" ? "__range_inc" : "__range_exc"), 1]]
    end
    return [["LOADTRUE", 0, 0, 0], ["RETURN", 0, 0, 0]] if insn.name == "RETTRUE"
    return [["LOADFALSE", 0, 0, 0], ["RETURN", 0, 0, 0]] if insn.name == "RETFALSE"
    nil
  end

  # メソッド表の中身: [クラス, シンボル, 飛び先] の列
  def self.method_entries(ctx)
    entries = []
    ctx.classes.each do |k|
      k.methods.each { |sym, m| entries << [k.id, ctx.sym_id(sym), m.base] if m.base }
      k.meta_methods.each { |sym, m| entries << [FpgaIsa::META | k.id, ctx.sym_id(sym), m.base] if m.base }
    end
    # クラスの名前 (Module#name)。include の写し (iclass) には無い
    if ctx.symbols.key?("__name_sym")
      ctx.classes.each { |k| entries << [k.id, FpgaIsa::NAME_SYM, ctx.sym_id(k.name)] unless k.origin }
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

    if FpgaIsa::JUMPS.include?(name) || name == "JMPUW"
      # mruby: pc は operand を読み終えた位置 (次の命令) から int16 で進む
      rel = b >= 0x8000 ? b - 0x10000 : b
      target = insn.next_addr + rel
      b = pc_of[target]
      unless b
        raise Error, "#{source}: #{name} at #{where(irep, insn)} jumps to byte #{target}, not an instruction boundary"
      end
      # JMPUW (while の中の break など) は ensure を畳みながら飛ぶ。catch handler の無い irep ではただの JMP
      return Word.new(pc, insn, FpgaIsa.op("JMP").num, 0, b, 0, irep) if name == "JMPUW"
    end

    if name == "GETGV" || name == "SETGV"
      sym = irep.syms[b]
      port = FpgaIoMap.fetch(sym)
      # ポートでなければ一般のグローバル変数: 定数の表の番号 (始めに nil にしてあるので、代入前に読むと nil)
      unless port
        return Word.new(pc, insn, FpgaIsa.op(name == "GETGV" ? "GETCONST" : "SETCONST").num, a, ctx.consts.fetch(sym), 0, irep)
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
      raise Error, "#{source}: super at #{where(irep, insn)} with keyword arguments is not supported yet" if (ops[1] >> 4) != 0
      return Word.new(pc, insn, insn.op.num, a, ctx.sym_id(ctx.method_names[irep.index]), argc | 0x80, irep)
    end

    # クラスの本体の attr_* / include / private など: 実行時は nil を置くだけ
    return Word.new(pc, insn, FpgaIsa.op("LOADNIL").num, a, 0, 0, irep) if ctx.noops[site_key(irep, k)]

    # A::X: 入れ物を GETCONST / GETMCNST の連なりから解き、クラスならその即値、定数なら番号
    if name == "GETMCNST" || name == "SETMCNST"
      base = const_path(ctx, irep, ctx.decoded[irep.index], k, name == "GETMCNST" ? a : a + 1)
      full = base ? "#{base}::#{irep.syms[b]}" : nil
      unless full && ctx.klass_named(base)
        raise Error, "#{source}: #{name} at #{where(irep, insn)} looks in something that is not a known class or module"
      end
      kl = ctx.klass_named(full)
      return Word.new(pc, insn, FpgaIsa.op("CLASS").num, a, kl.id, 0, irep) if kl && name == "GETMCNST"
      unless ctx.const_keys[full]
        raise Error, "#{source}: #{full} at #{where(irep, insn)} is not assigned anywhere in the program" if name == "GETMCNST"
      end
      return Word.new(pc, insn, FpgaIsa.op(name == "GETMCNST" ? "GETCONST" : "SETCONST").num, a, ctx.const_slot(full, full), 0, irep)
    end

    # 定数: 字句の入れ子の順に探す。クラスならその即値 (CLASS)、ほかは番号
    if name == "GETCONST" || name == "SETCONST"
      sym = irep.syms[b]
      scope = ctx.scope[irep.index]
      key = nil
      if name == "SETCONST"
        key = scope.id == FpgaIsa::CLS_OBJECT ? sym : "#{scope.name}::#{sym}"
      else
        ctx.lexical_names(ctx.cref[irep.index], sym).each do |n|
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

    # メソッドの呼び出し: b = シンボルの番号、c = 引数の数 | ブロックを渡す印 << 7。SSEND は self に送る。
    # 引数の数 15 は splat (R[a+1] が引数の配列)
    if %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(name)
      sym = irep.syms[ops[1]]
      argc = name.end_with?("0") ? 0 : ops[2] & 0xF
      kw = name.end_with?("0") ? 0 : ops[2] >> 4
      if kw != 0
        raise Error, "#{source}: #{sym} at #{where(irep, insn)} is called with keyword arguments (not supported yet)"
      end
      blk = name.end_with?("B")
      op = name.start_with?("SS") ? (blk ? "SSEND" : name) : (blk ? "SEND" : name)
      return Word.new(pc, insn, FpgaIsa.op(op).num, a, ctx.sym_id(sym), argc | (blk ? 0x80 : 0), irep)
    end

    # ENTER: a = 必須 m1、b = nregs、c = 省略可能 o | 残り r << 5 | 後ろの必須 m2 << 6 (&blk は印が要らない。
    # ブロックはいつも R[len+1] に置く)。メソッドもブロックも同じ (proc かどうかはコアが今の Proc で見る)
    if name == "ENTER"
      aspec = ops[0]
      if (aspec >> 1) & 0x3F != 0
        raise Error, "#{source}: #{ctx.parents[irep.index] ? 'block' : 'method'} at #{where(irep, insn)} takes keyword parameters (not supported yet)"
      end
      a = (aspec >> 18) & 0x1F
      b = irep.nregs
      c = ((aspec >> 13) & 0x1F) | (((aspec >> 12) & 1) << 5) | (((aspec >> 7) & 0x1F) << 6)
    end

    # ARGARY (引数なしの super): b は mruby のまま (m1 << 11 | r << 10 | m2 << 5 | kd << 4 | lv)。
    # ブロックの中 (lv > 0) とキーワード引数は止める (super はブロックの中では止めている)
    if name == "ARGARY"
      x = ops[1]
      raise Error, "#{source}: super at #{where(irep, insn)} forwards keyword parameters (not supported yet)" if (x >> 4) & 1 != 0
      raise Error, "#{source}: ARGARY at #{where(irep, insn)} reaches an outer frame" if (x & 0xF) != 0
      if a <= ((x >> 11) & 0x3F) + ((x >> 10) & 1) + ((x >> 5) & 0x1F) + 1
        raise Error, "#{source}: ARGARY at #{where(irep, insn)} writes over the arguments"
      end
    end

    # STRING: b = データの語アドレス、c = 長さ。LOADL: pool の整数を LOADI32 に
    if name == "STRING"
      str = irep.pool[b][1]
      return Word.new(pc, insn, insn.op.num, a, ctx.string_at.fetch(str), str.bytesize, irep)
    end
    if name == "LOADL"
      v = irep.pool[b][1] & 0xFFFF_FFFF
      return Word.new(pc, insn, FpgaIsa.op("LOADI32").num, a, v >> 16, v & 0xFFFF, irep)
    end

    # LOADSYM: b = プログラム全体で振ったシンボルの番号
    b = ctx.sym_id(irep.syms[ops[1]]) if name == "LOADSYM"

    # BLOCK / LAMBDA: Proc を作る。b = ブロックの irep の先頭 pc、c = lambda << 7 (引数と nregs はブロックの ENTER が持つ)
    if name == "BLOCK" || name == "LAMBDA"
      block = irep.reps[ops[1]]
      b = block.base
      c = ctx.lambdas[block.index] ? 0x80 : 0
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
