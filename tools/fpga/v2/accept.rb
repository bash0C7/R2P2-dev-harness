# v2 の合否の物差し (計画 S1、rake fpga:v2:accept)。mruby の test/t の file を host の PicoRuby と参照 v2 で走らせ、
# assert ごとの結果 (OK / KO / Crash / Warn / Skip) を比べる。1 本は shim、assert.rb、tally、test/t の file、report の 5 つの .rb で、
# host は picoruby の -r で前の 4 つを順に読んでから最後の 1 つを走らせる (「a,b,c」の形は file ごとの並行の task になり、出力の順が決まらない)。
# 参照 v2 は同じ 5 つを別々の .mrb にして起動の像の programs に順に並べる。
# 範囲外の assert は fpga/v2/accept/scope.tsv に理由 (乖離表の D 番号) と一緒に書き、理由は assert の本文から確かめる
require "open3"
require "tmpdir"
require_relative "build"

module FpgaV2
  module Accept
    ROOT = Build::ROOT
    MRUBY_DIR = File.join(ROOT, "vendor", "picoruby", "mrbgems", "picoruby-mruby", "lib", "mruby")
    TEST_DIR = File.join(MRUBY_DIR, "test", "t")
    ACCEPT_DIR = File.join(ROOT, "fpga", "v2", "accept")
    SCOPE = File.join(ACCEPT_DIR, "scope.tsv")
    IN_SCOPE_MIN = File.join(ACCEPT_DIR, "in_scope_min.txt")
    DEVIATIONS = File.join(ROOT, "docs", "fpga-v2-deviations.md")

    # 範囲外の理由 (乖離表の範囲の行) と、assert の本文に無ければならないもの
    REASONS = {
      "D30" => /\beval\b|compile/,
      "D31" => /Mrbtest|AryShared|__env_|TestVFormat|TestSysFail|TestNotImplement/,
      "D32" => /`/,
      "D33" => /GC\.stat\b|GC\.(generational_mode|step_limit|interval_ratio|step_ratio)/,
      "D34" => /PIO|USB|BOOTSEL|CYW43|BLE/
    }.freeze

    Row = Struct.new(:key, :name, :host, :ref, :scope, keyword_init: true)
    Result = Struct.new(:file, :rows, :host_out, :ref_out, :ref_error, :ref_stats, keyword_init: true) do
      def in_scope = rows.reject(&:scope)
      def same = in_scope.count { |r| r.host == r.ref }
    end

    module_function

    def names = Dir[File.join(TEST_DIR, "*.rb")].map { |f| File.basename(f, ".rb") }.sort

    def files(name)
      [File.join(ACCEPT_DIR, "shim.rb"), File.join(MRUBY_DIR, "test", "assert.rb"), File.join(ACCEPT_DIR, "tally.rb"),
       File.join(TEST_DIR, "#{name}.rb"), File.join(ACCEPT_DIR, "report.rb")]
    end

    # host の出力 (report の Time: の行は時間で変わるので消す)
    def host(name, picoruby:)
      *libs, main = files(name)
      out, = Open3.capture2e("timeout", "120", picoruby, *libs.flat_map { |f| ["-r", f] }, main)
      out.b.lines.reject { |l| l.start_with?("   Time: ") }.join
    end

    # 参照 v2 の出力と記録。止まったら ref_error に理由
    def ref(name, max_steps:)
      progs = files(name).map { |f| Build.compile([f]) }
      @firmware ||= Build.firmware
      r = Ref.new(Image.new(firmware: @firmware, programs: progs).build, max_steps: max_steps)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      err = nil
      begin
        r.run
      rescue StandardError => e # 参照 v2 に無い所 (Ref::Error) も、参照の不具合も、止まった理由として残す
        err = "#{e.class}: #{e.message}"
      end
      sec = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
      err ||= "halted before report" unless r.console.include?("  Total: ")
      [r.console.dup, err, { sec: sec, insn: r.steps, trap: r.stats[:trap], heap: r.heap_used }]
    end

    # "@@ <結果> <名前の inspect>" の行 → [[キー, 名前, 結果]]。同じ名前は出た順に #2 #3 を付ける
    def parse(out)
      seen = Hash.new(0)
      out.b.lines.filter_map do |l|
        next unless (m = l.chomp.match(/\A@@ (\w+) (".*")\z/n))

        name = begin
          m[2].dup.force_encoding(Encoding::UTF_8).undump
        rescue StandardError
          m[2]
        end
        seen[name] += 1
        [seen[name] == 1 ? name : "#{name} ##{seen[name]}", name, m[1]]
      end
    end

    # scope.tsv: file、assert の名前 (file 全部は *)、理由の D 番号。# で始まる行と空行は読まない
    def scope
      File.readlines(SCOPE, chomp: true, encoding: "UTF-8").reject { |l| l.empty? || l.start_with?("#") }.map do |l|
        file, name, code = l.split("\t")
        { file: file, name: name, code: code }
      end
    end

    # assert の本文 (assert(...) の行から、同じ字下げの end まで)
    def body(file, name)
      lines = File.readlines(File.join(TEST_DIR, "#{file}.rb"), encoding: "UTF-8")
      pat = Regexp.escape(name).gsub(/['"]/) { |q| "\\\\?#{q}" } # 本文では 'module\'s' のように \ が付く
      i = lines.index { |l| l =~ /\A(\s*)assert(_[a-z_]+)?\(\s*(['"])#{pat}\3/ } or return nil
      indent = lines[i][/\A\s*/]
      j = (i + 1...lines.size).find { |k| lines[k] =~ /\A#{indent}end\b/ } || lines.size - 1
      lines[i..j].join
    end

    # scope.tsv の行が正しいか: 理由が乖離表にあり、本文に理由の印がある。間違いの一覧を返す
    def check_scope(rows = scope)
      dev = File.read(DEVIATIONS, encoding: "UTF-8")
      rows.filter_map do |r|
        re = REASONS[r[:code]]
        next "#{r[:file]} #{r[:name]}: unknown reason #{r[:code]}" unless re
        next "#{r[:file]} #{r[:name]}: #{r[:code]} is not in the deviations table" unless dev.include?("| #{r[:code]} |")

        text = r[:name] == "*" ? File.read(File.join(TEST_DIR, "#{r[:file]}.rb"), encoding: "UTF-8") : body(r[:file], r[:name])
        next "#{r[:file]} #{r[:name]}: assert not found" unless text
        next "#{r[:file]} #{r[:name]}: body has no sign of #{r[:code]}" unless text.match?(re)
      end
    end

    def out_of_scope?(rows, file, name)
      rows.any? { |r| r[:file] == file && (r[:name] == "*" || r[:name] == name) }
    end

    # 1 file を host と参照 v2 で走らせて比べる
    def check(name, picoruby:, max_steps: 200_000_000, scope_rows: scope)
      h = host(name, picoruby: picoruby)
      r_out, err, st = ref(name, max_steps: max_steps)
      refs = parse(r_out).to_h { |k, _, res| [k, res] }
      rows = parse(h).map do |key, n, res|
        Row.new(key: key, name: n, host: res, ref: refs[key] || "Absent", scope: out_of_scope?(scope_rows, name, n))
      end
      Result.new(file: name, rows: rows, host_out: h, ref_out: r_out, ref_error: err, ref_stats: st)
    end
  end
end
