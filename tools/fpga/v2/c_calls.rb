# v2 の C の関数の動的な呼び出し (計画 S2-3)。棚卸しの各メソッドの C の関数から、呼ぶ C の関数を辿り (例外を上げる道は辿らない)、
# mrb_funcall* と mrb_type_convert* で呼ぶメソッドの名前を集める。firmware の def が SEND してよい先 (計画 S2-4) の基になる。
# C は板の define で前処理した (cc -E) ものを読む (#if の枝を板の条件で選ぶため)。前処理できない file は一覧 (problems) に残す
require "open3"
require_relative "vm_table"

module FpgaV2
  module CCalls
    # 動的に呼ぶ API と、メソッドの名前の引数の位置 (mrb を 0 番目として)
    # mrb_funcall* は全部 (argv1、with_block ほか) 2 番目、型の変換は 3 番目
    DISPATCH_API = /mrb_funcall\w*|mrb_type_convert(?:_check)?|convert_type/
    def self.name_index(api) = api.start_with?("mrb_funcall") ? 2 : 3
    # 例外を上げる道 (ここから先は辿らない。例外のメッセージを作るための inspect などが全部に付くため)
    # VM に入る所 (mrb_funcall* と mrb_yield* は呼ぶ先をこの表に書く。VM そのものは回路) も辿らない
    STOP = /raise|_error\z|\Amrb_format|\Amrb_exc_|\Amrb_bug\z|\Amrb_warn|\Amrb_funcall|\Amrb_yield|\Amrb_(vm_)?run\z|\Amrb_vm_exec\z|\Amrb_top_run\z/

    Fn = Struct.new(:name, :file, :calls, :dispatch, keyword_init: true)

    module_function

    def includes
      gems = Inventory.host_gems.filter_map { |g| d = Inventory.gem_dir(g) and File.join(d, "include") }.select { |d| File.directory?(d) }
      # gem の port の include は posix の物 (dir_hal_features.h などの形を読むだけ)。build が作る header (prism、フォントの表) は host の build から
      ports = Inventory.host_gems.filter_map { |g| d = Inventory.gem_dir(g) and File.join(d, "ports", "posix", "include") }.select { |d| File.directory?(d) }
      built = Dir[File.join(Inventory::HOST_BUILD, "mrbgems", "*", "include")]
      VmTable::INCLUDES + gems + ports + built +
        [File.join(Inventory::VENDOR, "include"), File.join(Inventory::GEMS_DIR, "mruby-compiler", "include"),
         File.join(Inventory::GEMS_DIR, "mruby-compiler", "lib", "prism", "include"), File.join(Inventory::ROOT, "build", "picoruby-fpga", "prism", "include")]
    end

    # 1 つの file の中で定義した関数
    def file_functions(path)
      out, st = Open3.capture2e("cc", "-E", *VmTable::DEFINES.map { |d| "-D#{d}" }, *includes.map { |i| "-I#{i}" }, path)
      return [nil, "#{Inventory.rel(path)}: cc -E failed (#{out.lines.grep(/: (fatal )?error:/).first.to_s.strip.split("error:").last.to_s.strip[0, 100]})"] unless st.success?

      lines = VmTable::Lines.new(out)
      funcs = VmTable.functions(out, lines).select { |f| lines.at(f.from)[0].to_s.end_with?(path.delete_prefix(Inventory::ROOT)) }
      fns = funcs.map do |f|
        body = out.byteslice(f.from, f.to - f.from)
        calls = body.scan(/\b([A-Za-z_]\w*)\s*\(/).flatten.uniq - VmTable::C_KEYWORDS
        dispatch = body.to_enum(:scan, /\b(#{DISPATCH_API})\s*\(/).filter_map do
          api = Regexp.last_match(1)
          args = Inventory.split_args(paren_args(body, Regexp.last_match.end(0)))
          a = args[name_index(api)] or next
          Inventory.sym_name(a) || resolved_sym(a) || local_sym(body, a) || "?(#{a.strip[0, 30]})"
        end
        dispatch << "(block)" if body.match?(/\bmrb_yield\w*\s*\(/)
        dispatch = [] if f.name.match?(/\A(#{DISPATCH_API})\z/) # 呼ぶメソッドを引数で受ける API の中は、呼ぶ側の所で名前を拾う
        Fn.new(name: f.name, file: Inventory.rel(path), calls: calls, dispatch: dispatch.uniq)
      end
      [fns, nil]
    end

    # 前処理の後、MRB_SYM(x) は数 (presym の番号) か mrb_intern_static(...) になっている
    def resolved_sym(expr)
      e = expr.strip.gsub(/\A\(|\)\z/, "")
      if e =~ /\A(\d+)\z/
        n = Regexp.last_match(1).to_i
        return Inventory.presym.find { |_, _| false } && nil if n.zero?

        @by_id ||= begin
          names = File.read(File.join(Inventory::PRESYM_DIR, "table.h"))[/presym_name_table\[\] = \{(.*?)\};/m, 1]
                      .scan(/^\s*"((?:[^"\\]|\\.)*)",/).map { |(s)| s.gsub(/\\(.)/, '\1') }
          names
        end
        return @by_id[n - 1]
      end
      Regexp.last_match(1) if e =~ /mrb_intern(?:_static|_cstr|_lit)?\(mrb,\s*"((?:[^"\\]|\\.)*)"/
    end

    # 関数の中の局所変数に入れたシンボル (mrb_sym mid = MRB_SYM(inherited); ... mrb_funcall_argv(mrb, s, mid, ...))。
    # 代入が 1 つだけの時に限る
    def local_sym(body, var)
      v = var.strip
      return nil unless v.match?(/\A[A-Za-z_]\w*\z/)

      rhs = body.scan(/\b#{v}\s*=\s*([^;=][^;]*);/).flatten.map(&:strip).uniq
      return nil unless rhs.size == 1

      Inventory.sym_name(rhs[0]) || resolved_sym(rhs[0])
    end

    # 位置 pos (開きかっこの後) から、対応する閉じかっこまでの中身
    def paren_args(text, pos)
      depth = 1
      i = pos
      while i < text.size && depth.positive?
        depth += 1 if text[i] == "("
        depth -= 1 if text[i] == ")"
        i += 1
      end
      text[pos...(i - 1)]
    end

    Result = Struct.new(:by_src, :problems, keyword_init: true)

    # 棚卸しの src (c:file:関数) ごとに、辿れる動的な呼び出しの名前
    def build(srcs)
      files = srcs.filter_map { |s| s[/\Ac:([^:]+):/, 1] }.uniq
      index = {} # [file, 名前] → Fn
      global = Hash.new { |h, k| h[k] = [] } # 名前 → [Fn]
      problems = []
      all_c = Inventory.c_files.map { |f| Inventory.rel(f) }
      (all_c | files).each do |rel|
        fns, pr = file_functions(File.join(Inventory::ROOT, rel))
        problems << pr if pr
        (fns || []).each do |f|
          index[[f.file, f.name]] = f
          global[f.name] << f
        end
      end
      resolve = lambda do |file, name|
        index[[file, name]] || (global[name].size == 1 ? global[name].first : nil)
      end
      memo = {}
      reach = lambda do |fn|
        return memo[fn] if memo.key?(fn)

        memo[fn] = [] # 環の間は空
        seen = {}
        queue = [fn]
        names = []
        until queue.empty?
          f = queue.shift
          next if seen[f]

          seen[f] = true
          names.concat(f.dispatch)
          f.calls.each do |c|
            next if c.match?(STOP) || c == f.name

            g = resolve.(f.file, c)
            queue << g if g
          end
        end
        memo[fn] = names.uniq.sort
      end
      by_src = srcs.uniq.to_h do |s|
        m = s.match(/\Ac:([^:]+):(\w+)\z/)
        next [s, nil] unless m

        f = resolve.(m[1], m[2])
        [s, f ? reach.(f) : nil]
      end
      Result.new(by_src: by_src, problems: problems)
    end
  end
end
