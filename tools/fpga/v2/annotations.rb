# firmware の写し元の注釈と、SEND 先の検査 (計画 S2-4)。
#   - firmware (fpga/firmware/*.rb) の def のすぐ上の行に `# C: <file> <名前> [(Dnn)]` か `# C: none (Dnn)` がある
#     <file> は mruby の置き場 (src/…、include/…、mrbgems/…) か picoruby の gem の置き場 (picoruby-…/…) からの path、
#     <名前> はその file の中にある識別子 (関数、CASE の OP_…、label、struct)。(Dnn) は乖離表 (docs/fpga-v2-deviations.md) の行
#   - def の中の SEND (GETIDX / SETIDX の [] / []= も) の先は、写し元の C の関数が動的に呼ぶもの (計画 S2-3) か、
#     firmware の helper と回路の primitive (__fpga_…) だけ。写し元が C の関数でない (none、irep、label) def は検査しない
require "prism"
require_relative "build"
require_relative "inventory"

module FpgaV2
  module Annotations
    DEVIATIONS = File.join(Inventory::ROOT, "docs", "fpga-v2-deviations.md")
    ANN = /\A\s*#\s*C:\s*(.+?)\s*\z/

    Def = Struct.new(:file, :line, :owner, :sing, :name, :ann, keyword_init: true)

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
        @defs << Def.new(file: File.basename(@path), line: node.location.start_line, owner: @owner.last, sing: !node.receiver.nil?,
                         name: node.name.to_s, ann: prev[ANN, 1])
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

    # firmware の def ごとの SEND 先 (入れ子の block も)。[持ち主, 特異か, 名前] → [名前…]
    def sends
      img = Image.new(firmware: Build.firmware)
      img.build
      top = img.irep_top(img.bytes(Build.firmware))
      out = {}
      regs = {}
      collect = lambda do |ir, acc|
        img.each_insn(ir) do |i|
          case i.name
          when /\AS?SEND/ then acc << img.sym_name(img.irep_sym(ir, i.b)) # SEND SEND0 SENDB SSEND SSEND0 SSENDB ほか
          when "GETIDX", "GETIDX0" then acc << "[]"
          when "SETIDX" then acc << "[]="
          end
        end
        img.irep_field(ir, Layout::I_RLEN).times { |k| collect.(img.irep_rep(ir, k), acc) }
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

            out[[owner, j.name == "SDEF", img.sym_name(img.irep_sym(body, j.b))]] = collect.(img.irep_rep(body, j.c), []).uniq
          end
        end
      end
      out
    end

    # SEND 先の間違い: 写し元の C の関数が動的に呼ばない先
    def check_sends
      require_relative "c_calls"
      sent = sends
      ds = defs.select { |d| d.ann }
      targets = ds.filter_map do |d|
        path, name, = parse(d.ann)
        next unless name && File.file?(path.to_s) && path.end_with?(".c")

        [d, "c:#{Inventory.rel(path)}:#{name}"]
      end
      dyn = CCalls.build(targets.map(&:last)).by_src
      targets.flat_map do |d, src|
        allowed = dyn[src] or next [] # C の関数でない名前 (label、CASE) は検査しない
        (sent[[d.owner, d.sing, d.name]] || []).reject { |s| s.start_with?("__fpga_") || allowed.include?(s) }.map do |s|
          "#{d.file}:#{d.line} #{d.owner}#{d.sing ? '.' : '#'}#{d.name} sends #{s} (#{d.ann} calls #{allowed.empty? ? 'nothing' : allowed.join(' ')})"
        end
      end
    end
  end
end
