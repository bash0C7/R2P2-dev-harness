# v2 の棚卸し (計画 S2、rake fpga:v2:inventory)。「何があるか」を 3 つから取り、突き合わせる:
#   1. host の reflection: fpga/v2/inventory/reflect.rb (mruby ソースコード) を host の PicoRuby で走らせる。正本 (#ifdef、alias、gem の後の結果)
#   2. C の走査: core の src/*.c と、host の build の gem (active_gems.txt) の src の、ROM の表 (MRB_MT_ENTRY + MRB_MT_INIT_ROM) と mrb_define_*
#   3. mrblib の走査: core と gem の mrblib/*.rb を CRuby の Prism で読む (class / module / def / attr_* / alias / private ほか)
# 1 にあって 2 ∪ 3 に無いもの、2 ∪ 3 にあって 1 に無いものは一覧に出す (黙って捨てない)。
# 板の gem の集合は R2P2 の build_config の gembox を、板の条件 (vm_mruby、posix でない) で評価して出す
require "open3"
require "prism"
require_relative "build"

module FpgaV2
  module Inventory
    ROOT = Build::ROOT
    VENDOR = File.join(ROOT, "vendor", "picoruby")
    GEMS_DIR = File.join(VENDOR, "mrbgems")
    MRUBY_DIR = File.join(GEMS_DIR, "picoruby-mruby", "lib", "mruby")
    HOST_BUILD = File.join(ROOT, "build", "picoruby-fpga", "host")
    PRESYM_DIR = File.join(HOST_BUILD, "include", "mruby", "presym")
    REFLECT = File.join(ROOT, "fpga", "v2", "inventory", "reflect.rb")
    OUT = File.join(ROOT, "fpga", "v2", "inventory.tsv")
    R2P2_CONFIG = File.join(VENDOR, "build_config", "r2p2-picoruby-pico2_w.upstream.rb")

    # mrb->xxx の組み込みのクラス (mruby.h の mrb_state)
    STATE_CLASSES = {
      "object_class" => "Object", "class_class" => "Class", "module_class" => "Module", "proc_class" => "Proc",
      "string_class" => "String", "array_class" => "Array", "hash_class" => "Hash", "range_class" => "Range",
      "float_class" => "Float", "integer_class" => "Integer", "true_class" => "TrueClass", "false_class" => "FalseClass",
      "nil_class" => "NilClass", "symbol_class" => "Symbol", "kernel_module" => "Kernel", "eException_class" => "Exception",
      "eStandardError_class" => "StandardError", "comparable_module" => "Comparable", "basic_object_class" => "BasicObject",
      "top_self" => "#<main>" # 一番外の self (main) の特異メソッドの持ち主は main
    }.freeze

    Entry = Struct.new(:kind, :owner, :name, :src, :gem, keyword_init: true) do
      def key = [owner, %w[sing spriv].include?(kind) ? "sing" : "inst", name]
    end

    module_function

    def rel(path) = path.delete_prefix("#{ROOT}/")

    # --- presym: MRB_SYM(x) などの名前 (build の id.h と table.h から)
    def presym
      @presym ||= begin
        names = File.read(File.join(PRESYM_DIR, "table.h"))[/presym_name_table\[\] = \{(.*?)\};/m, 1]
                    .scan(/^\s*"((?:[^"\\]|\\.)*)",/).map { |(s)| s.gsub(/\\(.)/, '\1') }
        File.read(File.join(PRESYM_DIR, "id.h")).scan(/^\s*(MRB_(?:OP|C|G|I|CV|IV|GV)?SYM(?:_[QEB])?)__(\w+) = (\d+),/).to_h do |k, n, i|
          ["#{k}(#{n})", names[i.to_i - 1]]
        end
      end
    end

    # "MRB_SYM(x)" か "\"x\"" の名前。分からなければ nil
    def sym_name(expr)
      e = expr.strip
      return Regexp.last_match(1) if e =~ /\A"((?:[^"\\]|\\.)*)"\z/
      return Regexp.last_match(1) if e =~ /\Amrb_intern_(?:lit|cstr)\(mrb,\s*"((?:[^"\\]|\\.)*)"\)\z/

      e = e.gsub(/\s+/, "")
      presym[e] || presym_rule(e)
    end

    # build の表に無い名前は、presym の名付けの決まり (mruby の lib/mruby/presym.rb) から作る。演算子 (MRB_OPSYM) は表だけ
    def presym_rule(e)
      m = e.match(/\AMRB_(SYM|SYM_Q|SYM_E|SYM_B|IVSYM|CVSYM|GVSYM)\((\w+)\)\z/) or return nil
      n = m[2]
      { "SYM" => n, "SYM_Q" => "#{n}?", "SYM_E" => "#{n}=", "SYM_B" => "#{n}!", "IVSYM" => "@#{n}", "CVSYM" => "@@#{n}",
        "GVSYM" => "$#{n}" }[m[1]]
    end

    # --- gem の置き場
    def gem_dir(name)
      [File.join(GEMS_DIR, name), File.join(MRUBY_DIR, "mrbgems", name)].find { |d| File.directory?(d) }
    end

    def host_gems = File.readlines(File.join(HOST_BUILD, "mrbgems", "active_gems.txt"), chomp: true).reject(&:empty?)

    def gem_of(path)
      case path
      when %r{/lib/mruby/mrbgems/([^/]+)/} then Regexp.last_match(1)
      when %r{/lib/mruby/(src|mrblib)/} then "mruby-core"
      when %r{/vendor/picoruby/mrbgems/([^/]+)/} then Regexp.last_match(1)
      end
    end

    def c_files
      core = Dir[File.join(MRUBY_DIR, "src", "*.c")]
      gems = host_gems.flat_map do |g|
        d = gem_dir(g) or next []
        Dir[File.join(d, "src", "**", "*.c")].reject { |f| f.include?("/mrubyc/") }
      end
      (core + gems).sort
    end

    def rb_files
      core = Dir[File.join(MRUBY_DIR, "mrblib", "*.rb")]
      gems = host_gems.flat_map do |g|
        d = gem_dir(g) or next []
        Dir[File.join(d, "mrblib", "**", "*.rb")]
      end
      (core + gems).sort
    end

    # --- 2. C の走査
    def strip_c_comments(src)
      src.gsub(%r{/\*.*?\*/}m) { |c| "\n" * c.count("\n") }.gsub(%r{//[^\n]*}, "")
    end

    # C の式 (クラスの変数、mrb->xxx、mrb_class_get など) → クラスの名前。特異クラスは "#<名前>"
    def resolve_class(expr, vars)
      e = expr.strip.sub(/\A\(struct RClass\s*\*\)\s*/, "")
      case e
      when /\Amrb->(\w+)\z/ then STATE_CLASSES[Regexp.last_match(1)]
      when /\Amrb_(?:class|module)_get(?:_id)?\(mrb,\s*(.+)\)\z/ then sym_name(Regexp.last_match(1))
      when /\Amrb_(?:class|module)_get_under(?:_id)?\(mrb,\s*(\w+(?:->\w+)?),\s*(.+)\)\z/
        outer = resolve_class(Regexp.last_match(1), vars)
        n = sym_name(Regexp.last_match(2))
        outer && n && (outer == "Object" ? n : "#{outer}::#{n}")
      when /\Amrb_singleton_class_ptr\(mrb,\s*mrb_obj_value\((.+)\)\)\z/
        c = resolve_class(Regexp.last_match(1), vars)
        c && "#<#{c}>"
      when /\A\w+\z/ then vars[e]
      end
    end

    DEFINE_CALL = /
      (?<assign>(?<var>\w+)\s*=\s*)?
      (?<fn>mrb_define_(?:class|module)(?:_under)?(?:_id)?|mrb_(?:class|module)_get(?:_under)?(?:_id)?|mrb_singleton_class_ptr
        |mrb_define_(?:method|private_method|class_method|singleton_method|module_function|alias|const)(?:_id|_raw)?
        |mrb_undef_(?:class_)?method(?:_id)?
        |mrb_define_global_const|MRB_MT_INIT_ROM)
      \(mrb,\s*(?<args>(?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*)\)
    /x

    # 引数を , で分ける (かっこの中の , は分けない)
    def split_args(s)
      out = []
      depth = 0
      cur = +""
      s.each_char do |ch|
        depth += 1 if ch == "("
        depth -= 1 if ch == ")"
        if ch == "," && depth.zero?
          out << cur.strip
          cur = +""
        else
          cur << ch
        end
      end
      out << cur.strip unless cur.strip.empty?
      out
    end

    # 関数の名前の位置 (C の関数の定義の始まり)
    def c_functions(src)
      src.to_enum(:scan, /^(?:static\s+)?(?:MRB_API\s+)?(?:mrb_value|void|mrb_bool|mrb_int)\s*\n?\s*(\w+)\s*\(mrb_state\s*\*\s*mrb/).map do
        [Regexp.last_match.begin(0), Regexp.last_match(1)]
      end
    end

    # クラスの変数の束ね方 (DEFINE_CALL の代入のほか)
    BINDS = {
      state: /\b(\w+)\s*=\s*mrb->(\w+)\s*[;=]/,                                  # c = mrb->string_class; / e = mrb->eException_class = ...
      back: /mrb->(\w+)\s*=\s*(\w+)\s*;/,                                        # mrb->module_class = mod;
      named: /mrb_class_name_class\(mrb,\s*NULL,\s*(\w+),\s*(MRB_SYM\(\w+\))\)/ # class.c の起動のクラスの名付け
    }.freeze

    # 1 つの file の中の、クラスの変数の束ね (file の外から使うための、他の file と合わない名前は捨てる)
    def c_bindings(path)
      vars = {}
      scan_c(path, vars: vars, bind_only: true)
      vars
    end

    def scan_c(path, vars: {}, bind_only: false)
      src = strip_c_comments(File.read(path, encoding: "UTF-8", invalid: :replace))
      gem = gem_of(path)
      tables = {}
      src.scan(/mrb_mt_entry\s+(\w+)\[\]\s*=\s*\{(.*?)\};/m) do |tname, body|
        tables[tname] = body.scan(/MRB_MT_ENTRY\(\s*(\w+)\s*,\s*(MRB_\w*SYM\w*\(\w+\))\s*,([^\n]*?)\)\s*,?\s*$/).map do |fn, sym, flags|
          [fn, sym_name(sym), flags.include?("MRB_MT_PRIVATE")]
        end
      end
      # クラスの変数は、書いた順に束ねる。ただし helper の関数が、定義より前の行で引数として受けて使うことがある (irq.c など)。
      # そこで 1 回目で file 全体の束ねを作り、2 回目はそれを出発点にして順に上書きしながら読む
      events = []
      src.scan(DEFINE_CALL) { events << [Regexp.last_match.begin(0), :call, Regexp.last_match] }
      BINDS.each { |tag, re| src.scan(re) { events << [Regexp.last_match.begin(0), tag, Regexp.last_match] } }
      events.sort_by!(&:first)
      scan_events(events, vars, path, gem, tables, bind_only: true)
      return [[], []] if bind_only

      scan_events(events, vars, path, gem, tables, bind_only: false)
    end

    def scan_events(events, vars, path, gem, tables, bind_only:)
      entries = []
      problems = []
      events.each do |_, tag, m|
        case tag
        when :state
          c = STATE_CLASSES[m[2]]
          vars[m[1]] = c if c
          next
        when :back
          c = STATE_CLASSES[m[1]]
          vars[m[2]] = c if c
          next
        when :named
          vars[m[1]] = sym_name(m[2])
          next
        end
        args = split_args(m[:args])
        fn = m[:fn]
        cls = case fn
              when /\Amrb_define_(class|module)(_id)?\z/, /\Amrb_(class|module)_get(_id)?\z/ then sym_name(args[0])
              when /\Amrb_define_(class|module)_under(_id)?\z/, /\Amrb_(class|module)_get_under(_id)?\z/
                outer = resolve_class(args[0], vars)
                n = sym_name(args[1])
                outer && n && (outer == "Object" ? n : "#{outer}::#{n}")
              when "mrb_singleton_class_ptr" then resolve_class("mrb_singleton_class_ptr(mrb, #{args[0]})", vars)
              end
        if cls && !bind_only && fn.start_with?("mrb_define_")
          # クラスとモジュールの定義は、入れ物の定数でもある
          outer, _, base = cls.rpartition("::")
          entries << Entry.new(kind: "const", owner: outer.empty? ? "Object" : outer, name: base, src: "c:#{rel(path)}", gem: gem)
        end
        if m[:var] && cls
          vars[m[:var]] = cls
          next
        end
        if m[:var] && fn =~ /\Amrb_(define_(class|module)|(class|module)_get)/
          vars[m[:var]] = nil # 名前が実行時に決まるクラス (data.c の Data.define など)。他の file の同じ名前に頼らない
          next
        end
        next if cls # 代入しない定義 (クラスを作るだけ)
        next if bind_only

        owner = resolve_class(args[0].to_s, vars)
        src_fn = ->(f) { "c:#{rel(path)}:#{f}" }
        case fn
        when "MRB_MT_INIT_ROM"
          t = tables[args[1]] or next problems << "#{rel(path)}: ROM table #{args[1]} not found"
          next problems << "#{rel(path)}: class of #{args[0]} for #{args[1]} not resolved" unless owner

          sing = owner.start_with?("#<")
          o = sing ? owner[2..-2] : owner
          t.each do |f, name, priv|
            next problems << "#{rel(path)}: #{f} has an unknown symbol" unless name

            entries << Entry.new(kind: sing ? "sing" : (priv ? "priv" : "pub"), owner: o, name: name, src: src_fn.(f), gem: gem)
          end
        when /\Amrb_define_(method|private_method|class_method|singleton_method|module_function)(_id|_raw)?\z/
          kind = Regexp.last_match(1)
          name = sym_name(args[1].to_s)
          next problems << "#{rel(path)}: #{fn}(#{args[0]}, #{args[1]}) not resolved" unless owner && name

          f = fn.end_with?("_raw") ? "-" : args[2].to_s[/\w+/]
          sing = owner.start_with?("#<")
          o = sing ? owner[2..-2] : owner
          case kind
          when "method" then entries << Entry.new(kind: sing ? "sing" : "pub", owner: o, name: name, src: src_fn.(f), gem: gem)
          when "private_method" then entries << Entry.new(kind: sing ? "spriv" : "priv", owner: o, name: name, src: src_fn.(f), gem: gem)
          when "class_method", "singleton_method" then entries << Entry.new(kind: "sing", owner: o, name: name, src: src_fn.(f), gem: gem)
          when "module_function"
            entries << Entry.new(kind: "sing", owner: o, name: name, src: src_fn.(f), gem: gem)
            entries << Entry.new(kind: "priv", owner: o, name: name, src: src_fn.(f), gem: gem)
          end
        when /\Amrb_undef_(class_)?method(_id)?\z/
          # 取り消しの印も表に入る (host の reflection は取り消した new を特異メソッドとして出す)
          name = sym_name(args[1].to_s)
          next problems << "#{rel(path)}: #{fn}(#{args[0]}, #{args[1]}) not resolved" unless owner && name

          entries << Entry.new(kind: Regexp.last_match(1) ? "sing" : "pub", owner: owner, name: name, src: "c:#{rel(path)}:undef", gem: gem)
        when /\Amrb_define_alias(_id)?\z/
          name = sym_name(args[1].to_s)
          old = sym_name(args[2].to_s)
          next problems << "#{rel(path)}: alias (#{args.join(', ')}) not resolved" unless owner && name

          entries << Entry.new(kind: "pub", owner: owner, name: name, src: "c:#{rel(path)}:alias(#{old})", gem: gem)
        when /\Amrb_define_const(_id)?\z/
          name = sym_name(args[1].to_s)
          next problems << "#{rel(path)}: const (#{args[0]}, #{args[1]}) not resolved" unless owner && name

          entries << Entry.new(kind: "const", owner: owner, name: name, src: "c:#{rel(path)}", gem: gem)
        when "mrb_define_global_const"
          name = sym_name(args[0].to_s)
          entries << Entry.new(kind: "const", owner: "Object", name: name, src: "c:#{rel(path)}", gem: gem) if name
        end
      end
      [entries, problems]
    end

    # --- 3. mrblib の走査 (Prism)
    class RbScan < Prism::Visitor
      attr_reader :entries

      def initialize(path, gem)
        super()
        @path = path
        @gem = gem
        @entries = []
        @scope = [["Object", :public, false]] # [持ち主, 既定の可視性, 特異クラスの中か]
      end

      def add(kind, owner, name)
        @entries << Entry.new(kind: kind, owner: owner, name: name.to_s, src: "mrblib:#{Inventory.rel(@path)}", gem: @gem)
      end

      def owner = @scope.last[0]

      def full(name)
        o = owner
        o == "Object" ? name : "#{o}::#{name}"
      end

      def enter(name)
        @scope.push([name, :public, false])
        yield
        @scope.pop
      end

      # クラスとモジュールの定義は、入れ物の定数でもある (class A::B なら A の定数 B)
      def define_const_of(node)
        name = full(node.constant_path.slice.delete_prefix("::"))
        outer, _, base = name.rpartition("::")
        add("const", outer.empty? ? "Object" : outer, base)
        name
      end

      def visit_class_node(node) = enter(define_const_of(node)) { super }
      def visit_module_node(node) = enter(define_const_of(node)) { super }

      def visit_singleton_class_node(node)
        # 一番外の class << self は main (一番外の self) の特異クラス
        @scope.push([@scope.size == 1 ? "main" : owner, :public, true])
        super
        @scope.pop
      end

      def vis_kind
        return(@scope.last[1] == :private ? "spriv" : "sing") if @scope.last[2]

        case @scope.last[1]
        when :private, :module_function then "priv"
        when :protected then "prot"
        else "pub"
        end
      end

      def visit_def_node(node)
        if node.receiver
          # 一番外の def self.x は main (一番外の self) の特異メソッド
          add("sing", @scope.size == 1 ? "main" : owner, node.name)
        else
          add(vis_kind, owner, node.name)
          add("sing", owner, node.name) if @scope.last[1] == :module_function && !@scope.last[2]
        end
        # def の中は読まない (中の def は実行時のもの)
      end

      def visit_alias_method_node(node)
        add(vis_kind, owner, node.new_name.slice.delete_prefix(":"))
      end

      def sym_args(node)
        (node.arguments&.arguments || []).filter_map { |a| a.unescaped if a.is_a?(Prism::SymbolNode) || a.is_a?(Prism::StringNode) }
      end

      def visit_call_node(node)
        return super if node.receiver

        case node.name
        when :private, :public, :protected, :module_function
          args = node.arguments&.arguments || []
          if args.empty?
            @scope.last[1] = node.name
          else
            names = args.filter_map { |a| a.name if a.is_a?(Prism::DefNode) } + sym_args(node)
            names.each do |n|
              if node.name == :module_function
                add("sing", owner, n)
                add("priv", owner, n)
              elsif @scope.last[2] # class << self の中
                add(node.name == :private ? "spriv" : "sing", owner, n)
              else
                add({ private: "priv", protected: "prot", public: "pub" }[node.name], owner, n)
              end
            end
          end
          return
        when :attr_reader, :attr_accessor, :attr, :attr_writer
          sym_args(node).each do |n|
            add(vis_kind, owner, n) unless node.name == :attr_writer
            add(vis_kind, owner, "#{n}=") if %i[attr_writer attr_accessor].include?(node.name)
          end
        when :private_class_method
          sym_args(node).each { |n| add("spriv", owner, n) }
        when :alias_method
          n = sym_args(node).first
          add(vis_kind, owner, n) if n
        when :define_method
          n = sym_args(node).first
          add(vis_kind, owner, n) if n
        end
        super
      end

      def visit_constant_write_node(node)
        add("const", owner, node.name) unless node.value.is_a?(Prism::CallNode) && %i[new].include?(node.value.name) &&
                                                   %w[Class Module].include?(node.value.receiver&.slice)
        super
      end
    end

    def scan_rb(path)
      v = RbScan.new(path, gem_of(path))
      Prism.parse_file(path).value.accept(v)
      v.entries
    end

    # --- 1. host の reflection
    def reflect(picoruby: Build.mrbc.sub(/mrbc\z/, "picoruby"))
      out, st = Open3.capture2e(picoruby, REFLECT)
      raise "reflect.rb failed on host:\n#{out}" unless st.success?

      out.lines(chomp: true).map do |l|
        kind, owner, name = l.split("\t", 3)
        Entry.new(kind: kind, owner: owner, name: name, src: nil, gem: nil)
      end
    end

    # --- 板の gem の集合 (R2P2 の build_config の gembox を、板の条件で評価する)
    class Conf
      attr_reader :gems

      def initialize = @gems = []
      def posix? = false
      def vm_mruby? = true
      def picoruby? = true
      def vm_mrubyc? = false
      def femtoruby? = false
      def wasm? = false
      def platform?(_name) = false

      def gem(core: nil, gemdir: nil, **)
        n = core || (gemdir && File.basename(gemdir))
        @gems << n if n
      end

      def gembox(name)
        path = [File.join(GEMS_DIR, "#{name}.gembox"), File.join(MRUBY_DIR, "mrbgems", "#{name}.gembox")].find { |p| File.exist?(p) }
        raise "gembox #{name} not found" unless path

        body = File.read(path).sub(/\A\s*MRuby::GemBox\.new do \|conf\|\n/, "").sub(/end\s*\z/, "")
        instance_eval(body, path)
      end

      def conf = self
      MRUBY_ROOT = VENDOR

      def picoruby(**) = gem(core: "picoruby-mruby")
      def method_missing(*) = Sink.new
      def respond_to_missing?(*) = true
    end

    # build の設定の知らない所 (cc.defines など)。問い (xxx?、=~、include?) は偽を返す
    class Sink
      def method_missing(name, *) = name.end_with?("?") ? false : self
      def respond_to_missing?(*) = true
      def <<(_) = self
      def =~(_) = nil
      def to_s = ""
      def to_str = ""
    end

    # mrbgem.rake の MRuby::Gem::Specification.new do |spec| ... end を、板の build (Conf) で評価して add_dependency を拾う
    class Spec
      attr_reader :deps

      def initialize(build)
        @build = build
        @deps = []
      end

      def build = @build
      def add_dependency(name, *, **) = @deps << name
      def add_test_dependency(*, **) = nil
      def method_missing(name, *) = name.end_with?("?") ? false : Sink.new
      def respond_to_missing?(*) = true
    end

    module GemRake
      MRUBY_ROOT = VENDOR

      # MRUBY_CONFIG などの build の定数は知らない物として扱う (問いは偽)
      def self.const_missing(_) = Sink.new

      # mrbgem.rake の中の Rake の task の定義は読まない
      module Rake
        def self.const_missing(_) = SinkClass
        def self.method_missing(*) = Sink.new
        def self.respond_to_missing?(*) = true
      end

      class SinkClass
        def self.new(*) = Sink.new
        def self.method_missing(*) = Sink.new
        def self.respond_to_missing?(*) = true
      end

      module MRuby
        module Gem
          class Specification
            def self.new(_name = nil, &blk)
              spec = GemRake.current
              spec.instance_exec(spec, &blk)
              spec
            end
          end
        end
      end

      class << self
        attr_accessor :current
      end
    end

    # 評価できなかった mrbgem.rake は、条件なしの add_dependency の行で代え、一覧 (dep_problems) に残す
    def gem_deps(rake, build)
      GemRake.current = Spec.new(build)
      GemRake.module_eval(File.read(rake), rake)
      GemRake.current.deps
    rescue StandardError, ScriptError => e
      (@dep_problems ||= []) << "#{rel(rake)}: not evaluated (#{e.class}), dependencies read without conditions"
      File.read(rake).scan(/add_dependency\s*\(?\s*["']([\w-]+)["']/).flatten
    end

    def dep_problems = @dep_problems || []

    # R2P2 の build_config の gem と gembox を拾う (conf.gem core: / conf.gembox の行だけを、条件なしで)
    def board_gems
      conf = Conf.new
      File.readlines(R2P2_CONFIG).each do |l|
        if l =~ /^\s*conf\.gembox\s+["'](\S+)["']/
          conf.gembox(Regexp.last_match(1))
        elsif l =~ /^\s*conf\.gem\s+core:\s*["'](\S+)["']/
          conf.gem(core: Regexp.last_match(1))
        elsif l =~ /^\s*conf\.picoruby\b/
          conf.picoruby
        end
      end
      with_deps(conf.gems.uniq)
    end

    # mrbgem.rake の add_dependency を、板の条件で評価して辿る
    def with_deps(gems)
      build = Conf.new
      all = []
      queue = gems.dup
      until queue.empty?
        g = queue.shift
        next if all.include?(g)

        all << g
        d = gem_dir(g) or next
        rake = File.join(d, "mrbgem.rake")
        next unless File.exist?(rake)

        queue.concat(gem_deps(rake, build))
      end
      all.sort
    end

    # --- 突き合わせ
    Result = Struct.new(:rows, :host_only, :source_only, :problems, :board, :host, keyword_init: true)

    def build(picoruby: nil)
      host = picoruby ? reflect(picoruby: picoruby) : reflect
      c_entries = []
      problems = []
      # file をまたぐクラスの変数 (task.c の task_class を task_queue.c が使うなど): 全 file で同じクラスに束ねた名前だけを使う
      global = {}
      c_files.each { |f| c_bindings(f).each { |k, v| global[k] = global.key?(k) && global[k] != v ? :conflict : v } }
      global.reject! { |_, v| v == :conflict }
      c_files.each do |f|
        e, pr = scan_c(f, vars: global.dup)
        c_entries.concat(e)
        problems.concat(pr)
      end
      rb_entries = rb_files.flat_map { |f| scan_rb(f) }
      sources = (c_entries + rb_entries).group_by(&:key)
      host_keys = host.group_by(&:key)
      board = board_gems
      rows = host.map do |h|
        s = sources[h.key]
        srcs = s ? s.map(&:src).uniq : []
        gems = s ? s.map(&:gem).compact.uniq : []
        { kind: h.kind, owner: h.owner, name: h.name, src: srcs.empty? ? "-" : srcs.join(" "),
          gem: gems.empty? ? "-" : gems.join(" "), board: gems.empty? ? "?" : (gems.any? { |g| g == "mruby-core" || board.include?(g) } ? "yes" : "no") }
      end
      host_only = rows.select { |r| r[:src] == "-" }
      source_only = sources.reject { |k, _| host_keys[k] }.values.map(&:first)
      Result.new(rows: rows.sort_by { |r| [r[:owner], r[:kind], r[:name]] }, host_only: host_only, source_only: source_only,
                 problems: problems, board: board, host: host_gems)
    end

    UNMATCHED = File.join(ROOT, "fpga", "v2", "inventory", "unmatched.tsv")

    # 突き合わせで合わなかったもの。1 行に 種類<TAB>中身。黙って捨てずに commit して、増えたら inventory_test が気づく
    def unmatched_tsv(result, arena_outside_ops: [])
      rows = []
      arena_outside_ops.each { |fn, line| rows << ["arena_outside_ops", "vm.c #{fn} (#{line} 行目の目安)"] }
      result.host_only.each { |r| rows << ["host_only", "#{r[:kind]} #{r[:owner]} #{r[:name]}"] }
      result.source_only.each { |e| rows << ["source_only", "#{e.kind} #{e.owner} #{e.name} #{e.src}"] }
      result.problems.each { |p| rows << ["unresolved", p] }
      (result.board - result.host).each { |g| rows << ["board_gem_not_on_host", g] }
      dep_problems.each { |p| rows << ["gem_deps", p] }
      "# 棚卸しの突き合わせで合わなかったもの (rake fpga:v2:inventory が作る)\n" \
        "# host_only: host にあるが C と mrblib に見つからない / source_only: C か mrblib にあるが host に無い (#ifdef、条件付きの定義)\n" \
        "# unresolved: C の定義の呼び出しでクラスか名前が決まらない (定義の API の中身、実行時に名前が決まるクラス)\n" \
        "# board_gem_not_on_host: 板 (R2P2) の gem で host の build に無い (計画 V4 で host の build に足す)\n" \
        "# arena_outside_ops: vm.c の arena の restore で、どの命令からも辿れない所 (fpga/v2/inventory/ops.tsv)\n" +
        rows.sort.map { |r| r.join("\t") }.join("\n") + "\n"
    end

    def tsv(result)
      head = "# 棚卸し (計画 S2-1、rake fpga:v2:inventory が作る。手で書かない)\n" \
             "# kind<TAB>owner<TAB>name<TAB>src (c:file:関数 / mrblib:file / - は見つからない)<TAB>gem<TAB>board (板の gem の集合に入るか)\n"
      head + result.rows.map { |r| [r[:kind], r[:owner], r[:name], r[:src], r[:gem], r[:board]].join("\t") }.join("\n") + "\n"
    end
  end
end
