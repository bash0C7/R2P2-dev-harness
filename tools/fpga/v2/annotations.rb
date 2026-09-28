# firmware の写し元の注釈と、SEND 先の検査 (計画 S2-4)。
#   - firmware (fpga/firmware/*.rb) の def のすぐ上の行に `# C: <file> <名前> [(Dnn)]` か `# C: none (Dnn)` がある
#     <file> は mruby の置き場 (src/…、include/…、mrbgems/…) か picoruby の gem の置き場 (picoruby-…/…) からの path、
#     <名前> はその file の中にある識別子 (関数、CASE の OP_…、label、struct)。(Dnn) は乖離表 (docs/fpga-v2-deviations.md) の行
#   - def の中の SEND (GETIDX / SETIDX の [] / []= も) の先は、写し元の C の関数が動的に呼ぶもの (計画 S2-3) か、
#     firmware の helper と回路の primitive (__fpga_…) だけ。写し元が C の関数でない (none、irep、label) def は検査しない
#   - C のメソッドの写しの def は、引数の数の範囲が C の aspec (棚卸しの aspec の列) と同じ。mruby は C の関数を呼ぶ前に
#     aspec で数を調べる (vm.c の check_argument_count)。*args で受けるなら、本文で __fpga_check_argc(args, min, max) を呼ぶ
require "prism"
require_relative "build"
require_relative "inventory"

module FpgaV2
  module Annotations
    DEVIATIONS = File.join(Inventory::ROOT, "docs", "fpga-v2-deviations.md")
    ANN = /\A\s*#\s*C:\s*(.+?)\s*\z/

    Def = Struct.new(:file, :line, :owner, :sing, :name, :ann, :min, :max, :rest, :body, keyword_init: true)

    class Visitor < Prism::Visitor
      attr_reader :defs

      def initialize(path, lines)
        super()
        @path = path
        @lines = lines
        @owner = ["Object"]
        @defs = []
      end

      def visit_class_node(node) = (@owner << node.constant_path.slice; super; @owner.pop)
      def visit_module_node(node) = (@owner << node.constant_path.slice; super; @owner.pop)

      def visit_def_node(node)
        prev = @lines[node.location.start_line - 2].to_s
        pr = node.parameters
        req = pr ? pr.requireds.size + pr.posts.size : 0
        opt = pr ? pr.optionals.size : 0
        rest = pr&.rest.is_a?(Prism::RestParameterNode) ? pr.rest.name.to_s : nil
        @defs << Def.new(file: File.basename(@path), line: node.location.start_line, owner: @owner.last, sing: !node.receiver.nil?,
                         name: node.name.to_s, ann: prev[ANN, 1], min: req, max: rest ? -1 : req + opt, rest: rest,
                         body: node.body&.slice.to_s)
      end
    end

    module_function

    def defs
      Build.firmware_sources.flat_map do |f|
        v = Visitor.new(f, File.readlines(f))
        Prism.parse_file(f).value.accept(v)
        v.defs
      end
    end

    def deviations = @deviations ||= File.read(DEVIATIONS).scan(/^\| (D\d+) \|/).flatten

    # 注釈 → [path (絶対), 名前, D 番号] か [nil, nil, D 番号] (none)
    def parse(ann)
      if (m = ann.match(/\Anone \((D\d+)\)\z/))
        [nil, nil, m[1]]
      elsif (m = ann.match(/\A(\S+)\s+(\w+)(?:\s+\((D\d+)\))?\z/))
        path = [File.join(Inventory::MRUBY_DIR, m[1]), File.join(Inventory::GEMS_DIR, m[1])].find { |p| File.file?(p) }
        [path || m[1], m[2], m[3]]
      end
    end

    # 注釈の間違いの一覧
    def check
      defs.filter_map do |d|
        where = "#{d.file}:#{d.line} #{d.owner}#{d.sing ? '.' : '#'}#{d.name}"
        next "#{where}: no `# C:` annotation on the line above" unless d.ann

        path, name, dev = parse(d.ann)
        next "#{where}: bad annotation `#{d.ann}`" unless dev || name
        next "#{where}: #{dev} is not in the deviations table" if dev && !deviations.include?(dev)
        next unless name
        next "#{where}: #{path} does not exist" unless File.file?(path)
        next "#{where}: #{name} is not in #{File.basename(path)}" unless File.read(path, encoding: "UTF-8", invalid: :replace).match?(/\b#{name}\b/)
      end
    end

    LAYOUT = File.join(Inventory::ROOT, "tools", "fpga", "v2", "layout.rb")

    # layout.rb: 定数の行は、同じ行か、その上の (空行をはさまない) 注釈の塊に `# C:` がある。注釈の中身も確かめる
    def check_layout
      covered = false
      errors = []
      File.readlines(LAYOUT, encoding: "UTF-8").each_with_index do |l, i|
        covered = false if l.strip.empty?
        if (ann = l[ANN, 1])
          covered = true
          path, name, dev = parse(ann)
          errors << "layout.rb:#{i + 1}: bad annotation `#{ann}`" unless dev || name
          errors << "layout.rb:#{i + 1}: #{dev} is not in the deviations table" if dev && !deviations.include?(dev)
          if name && !(File.file?(path.to_s) && File.read(path).match?(/\b#{name}\b/))
            errors << "layout.rb:#{i + 1}: #{name} is not in #{path}"
          end
        end
        const = l[/\A\s*([A-Z][A-Z0-9_]*)\s*=/, 1]
        errors << "layout.rb:#{i + 1}: #{const} has no `# C:` annotation" if const && !covered && !l.include?("C:")
      end
      errors
    end

    # firmware の def ごとの SEND 先と命令の名前 (入れ子の block も)。[持ち主, 特異か, 名前] → [[名前…], [命令…]]
    def insns
      @insns ||= begin
        img = Image.new(firmware: Build.firmware)
        img.build
        top = img.irep_top(img.bytes(Build.firmware))
        out = {}
        regs = {}
        collect = lambda do |ir, acc, ops|
          img.each_insn(ir) do |i|
            ops << i.name
            case i.name
            when /\AS?SEND/ then acc << img.sym_name(img.irep_sym(ir, i.b)) # SEND SEND0 SENDB SSEND SSEND0 SSENDB ほか
            when "GETIDX", "GETIDX0" then acc << "[]"
            when "SETIDX" then acc << "[]="
            end
          end
          img.irep_field(ir, Layout::I_RLEN).times { |k| collect.(img.irep_rep(ir, k), acc, ops) }
          acc
        end
        img.each_insn(top) do |i|
          case i.name
          when "CLASS", "MODULE" then regs[i.a] = img.sym_name(img.irep_sym(top, i.b))
          when "EXEC"
            body = img.irep_rep(top, i.b)
            owner = regs.fetch(i.a)
            img.each_insn(body) do |j|
              next unless %w[TDEF SDEF].include?(j.name)

              ops = []
              sends = collect.(img.irep_rep(body, j.c), [], ops).uniq
              out[[owner, j.name == "SDEF", img.sym_name(img.irep_sym(body, j.b))]] = [sends, ops.uniq]
            end
          end
        end
        out
      end
    end

    def sends = insns.transform_values(&:first)

    # C の動的な呼び出しと GC の関所の種類 (c_calls.rb)。firmware の def の写し元の C の関数の全部について 1 回だけ作る
    def c_targets
      defs.select(&:ann).filter_map do |d|
        path, name, = parse(d.ann)
        next unless name && File.file?(path.to_s) && path.end_with?(".c")

        [d, "c:#{Inventory.rel(path)}:#{name}"]
      end
    end

    def ccalls
      require_relative "c_calls"
      @ccalls ||= CCalls.build(c_targets.map(&:last))
    end

    # 物を作る命令 (計画 S6 §3.5: GC の中では確保しない)
    ALLOC_OPS = %w[ARRAY ARRAY2 ARYCAT ARYPUSH ARYSPLAT STRING STRCAT HASH HASHADD HASHCAT LAMBDA BLOCK METHOD RANGE_INC RANGE_EXC INTERN
                   APOST].freeze
    # GC の本体の file (S6-4 から)。その def は物を作る命令を持たない
    GC_FILES = %w[gc.rb].freeze

    # 間違いの一覧: GC の file の def が物を作る命令を持つ、firmware のどこかに Proc を作る命令 (LAMBDA / BLOCK / METHOD) がある
    def check_alloc_ops
      ins = insns
      errors = []
      defs.each do |d|
        ops = ins[[d.owner, d.sing, d.name]]&.last or next
        where = "#{d.file}:#{d.line} #{d.owner}#{d.sing ? '.' : '#'}#{d.name}"
        (ops & %w[LAMBDA BLOCK METHOD]).each { |o| errors << "#{where}: #{o} makes a Proc in firmware (plan S6 §3.4)" }
        next unless GC_FILES.include?(d.file)

        (ops & ALLOC_OPS).each { |o| errors << "#{where}: #{o} allocates inside the GC (plan S6 §3.5)" }
      end
      errors
    end

    GC_CALLS = File.join(Inventory::ROOT, "fpga", "v2", "inventory", "gc_calls.tsv")

    # GC の関所の表 (計画 S6 §3.5)。firmware の def ごとに、写し元の C の関数が辿って使う GC の API の種類と、
    # firmware の def が __fpga_ の helper を辿って使う種類 (`# C:` がその API の def に着いた所)。足りない種類を最後の列に
    def gc_rows
      require_relative "c_calls"
      by_name = Hash.new { |h, k| h[k] = [] }
      defs.each { |d| by_name[d.name] << d }
      ins = insns
      api_of = lambda do |d|
        _, name, = d.ann ? parse(d.ann) : nil
        name
      end
      fw_reach = lambda do |d0|
        seen = {}
        queue = [d0]
        kinds = []
        until queue.empty?
          d = queue.shift
          next if seen[d]

          seen[d] = true
          api = api_of.(d)
          if d != d0 && api && CCalls::GC_API.key?(api)
            kinds << CCalls::GC_API[api]
            next
          end
          next if d != d0 && api&.match?(CCalls::GC_LEAF)

          (ins[[d.owner, d.sing, d.name]]&.first || []).each do |s|
            next unless s.start_with?("__fpga_")

            by_name[s].each { |x| queue << x }
          end
        end
        kinds.uniq.sort
      end
      c_of = c_targets.to_h { |d, src| [d, src] }
      rows = defs.filter_map do |d|
        src = c_of[d]
        need = src ? (ccalls.gc_by_src[src] || []) : []
        have = fw_reach.(d)
        next if need.empty? && have.empty?

        ["#{d.file} #{d.owner}#{d.sing ? '.' : '#'}#{d.name}", d.ann.to_s, need.join(" "), have.join(" "), (need - have).join(" ")]
      end
      rows.sort
    end

    def gc_calls_tsv(rows = gc_rows)
      "# GC の関所 (計画 S6 §3.5、rake fpga:v2:inventory が作る。手で書かない)。写し元の C の関数が辿って使う GC の API\n" \
        "# (arena_save arena_restore protect register barrier free realloc) を firmware の def も使うか。最後の列が足りない種類\n" \
        "# def<TAB>写し元<TAB>C<TAB>firmware<TAB>足りない\n" + rows.map { |r| r.join("\t") }.join("\n") + "\n"
    end

    # 棚卸しの aspec ("1"、"0..1"、"1+"、k 付き) → [min, max] (max -1 は上限無し)
    def aspec_range(s)
      m = s.delete_suffix("k").match(/\A(\d+)(?:\.\.(\d+)|(\+))?\z/) or return nil
      min = m[1].to_i
      [min, m[3] ? -1 : (m[2] ? m[2].to_i : min)]
    end

    # 引数の数の間違い: C のメソッドの写しの def が、C の aspec と違う数を受ける
    def check_aspec
      rows = File.readlines(Inventory::OUT, chomp: true).reject { |l| l.start_with?("#") }.map { |l| l.split("\t") }
      by_src = Hash.new { |h, k| h[k] = [] }
      rows.each { |r| r[3].to_s.split(" ").each { |s| by_src[[s, r[2]]] << r[7].to_s } }
      defs.filter_map do |d|
        next unless d.ann

        path, fn, = parse(d.ann)
        next unless fn && File.file?(path.to_s) && path.end_with?(".c")

        asps = by_src[["c:#{Inventory.rel(path)}:#{fn}", d.name]].flat_map { |a| a.split(" ") }.uniq
        ranges = asps.filter_map { |a| aspec_range(a) }
        next if ranges.empty?
        next if ranges.any? { |mn, mx| d.min == mn && d.max == mx }
        next if d.rest && d.min.zero? && ranges.any? { |mn, mx| d.body.include?("__fpga_check_argc(#{d.rest}, #{mn}, #{mx})") }

        want = ranges.map { |mn, mx| mx.negative? ? "#{mn}+" : (mn == mx ? mn.to_s : "#{mn}..#{mx}") }.join(" or ")
        got = d.max.negative? ? "#{d.min}+" : (d.min == d.max ? d.min.to_s : "#{d.min}..#{d.max}")
        "#{d.file}:#{d.line} #{d.owner}#{d.sing ? '.' : '#'}#{d.name} takes #{got} (#{d.ann} takes #{want})"
      end
    end

    # SEND 先の間違い: 写し元の C の関数が動的に呼ばない先
    def check_sends
      sent = sends
      dyn = ccalls.by_src
      c_targets.flat_map do |d, src|
        allowed = dyn[src] or next [] # C の関数でない名前 (label、CASE) は検査しない
        (sent[[d.owner, d.sing, d.name]] || []).reject { |s| s.start_with?("__fpga_") || allowed.include?(s) }.map do |s|
          "#{d.file}:#{d.line} #{d.owner}#{d.sing ? '.' : '#'}#{d.name} sends #{s} (#{d.ann} calls #{allowed.empty? ? 'nothing' : allowed.join(' ')})"
        end
      end
    end
  end
end
