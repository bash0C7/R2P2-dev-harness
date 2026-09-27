# v2 の命令の表 (計画 S2-2、rake fpga:v2:inventory が一緒に作る)。mruby の vm.c を板の define で前処理し (cc -E)、
# mrb_vm_exec の中を命令ごとの区間 (CASE が作る L_OP_<名前>_BODY: から次の CASE まで) に分ける。各命令について、
#   - その区間から goto で行く label の区間と、呼ぶ vm.c の static 関数 (その先の static 関数も) までを辿り、
#   - arena の restore (mrb_gc_arena_restore / mrb_gc_arena_shrink、前処理の後は gc.arena_idx への代入) の所と、
#   - 呼ぶ vm.c の外の関数 (mruby の C の API。firmware が写す先)
# を列にする。どの命令からも辿れない restore の所は、別の一覧に出す (黙って捨てない)
require "open3"
require "tmpdir"
require_relative "inventory"

module FpgaV2
  module VmTable
    ROOT = Inventory::ROOT
    MRUBY_DIR = Inventory::MRUBY_DIR
    VM_C = File.join(MRUBY_DIR, "src", "vm.c")
    OPS_H = File.join(MRUBY_DIR, "include", "mruby", "ops.h")
    OUT = File.join(ROOT, "fpga", "v2", "inventory", "ops.tsv")

    # 板の build の define (R2P2 の build_config と、picoruby-mruby の mrbgem.rake の組み込みの profile)
    DEFINES = %w[MRB_INT64 MRB_NO_BOXING MRB_32BIT MRB_UTF8_STRING MRB_CONSTRAINED_BASELINE_PROFILE=1 MRB_HEAP_PAGE_SIZE=128
                 PICORB_VM_MRUBY MRB_USE_TASK_SCHEDULER MRB_TICK_UNIT=1 MRB_TIMESLICE_TICK_COUNT=10].freeze
    INCLUDES = [File.join(MRUBY_DIR, "include"), File.join(Inventory::HOST_BUILD, "include"),
                File.join(MRUBY_DIR, "mrbgems", "mruby-task", "include"),
                File.join(Inventory::GEMS_DIR, "picoruby-mruby", "include")].freeze

    RESTORE = /->gc\.arena_idx\s*=(?!=)|\bmrb_gc_arena_shrink\s*\(/
    SAVE = /->gc\.arena_idx\)/
    C_KEYWORDS = %w[if while for switch return sizeof case do else goto typeof __typeof__ __builtin_expect __attribute__
                    __extension__ __builtin_offsetof _Static_assert __asm__ defined].freeze

    Func = Struct.new(:name, :from, :to, :vm_c, keyword_init: true)

    module_function

    def preprocess
      out, st = Open3.capture2e("cc", "-E", *DEFINES.map { |d| "-D#{d}" }, *INCLUDES.map { |i| "-I#{i}" }, VM_C)
      raise "cc -E vm.c failed:\n#{out[0, 2000]}" unless st.success?

      out
    end

    # 前処理の結果の位置 → 元の file と行 (# 行番号 "file" の印から)
    class Lines
      def initialize(text)
        @marks = []
        pos = 0
        text.each_line do |l|
          if l =~ /\A# (\d+) "([^"]+)"/
            @marks << [pos + l.bytesize, Regexp.last_match(1).to_i, Regexp.last_match(2)]
          end
          pos += l.bytesize
        end
        @text = text
      end

      def at(pos)
        i = @marks.bsearch_index { |m| m[0] > pos } || @marks.size
        m = @marks[i - 1] or return [nil, 0]
        [m[2], m[1] + @text.byteslice(m[0], pos - m[0]).count("\n")]
      end
    end

    # 一番外の {} の関数の本体 (文字列と文字の定数は飛ばす)
    def functions(text, lines)
      funcs = []
      depth = 0
      start = nil
      i = 0
      n = text.bytesize
      while i < n
        c = text.getbyte(i)
        case c
        when 34, 39 # " '
          q = c
          i += 1
          while i < n && text.getbyte(i) != q
            i += 1 if text.getbyte(i) == 92
            i += 1
          end
        when 35 # 行の頭の # (前処理の印)
          i = (text.index("\n", i) || n) if i.zero? || text.getbyte(i - 1) == 10
        when 123 # {
          if depth.zero?
            head = text.byteslice([0, i - 400].max, i - [0, i - 400].max)
            head = head[/[;}]\s*([^;}]*)\z/m, 1] || head
            if (m = head.match(/\b([A-Za-z_]\w*)\s*\([^()]*(?:\([^()]*\)[^()]*)*\)\s*\z/m)) && !C_KEYWORDS.include?(m[1]) && head !~ /=\s*\z/
              start = [m[1], i]
            else
              start = nil
            end
          end
          depth += 1
        when 125 # }
          depth -= 1
          if depth.zero? && start
            file, = lines.at(start[1])
            funcs << Func.new(name: start[0], from: start[1], to: i, vm_c: file.to_s.end_with?("src/vm.c"))
            start = nil
          end
        end
        i += 1
      end
      funcs
    end

    # ops.h の命令の並びと、operand の形
    def ops
      File.read(OPS_H).scan(/^OPCODE\((\w+),\s*(\w+)\)/)
    end

    Site = Struct.new(:kind, :line, :where, keyword_init: true)

    def build
      text = preprocess
      lines = Lines.new(text)
      funcs = functions(text, lines)
      exec = funcs.find { |f| f.name == "mrb_vm_exec" } or raise "mrb_vm_exec not found"
      statics = funcs.select(&:vm_c).to_h { |f| [f.name, f] }
      defined_here = funcs.map(&:name) # header の inline 関数も含む (外の関数だけを列にする)
      body = text.byteslice(exec.from, exec.to - exec.from)

      # 区間: L_OP_<名前>_BODY: の位置から次の命令の区間まで
      starts = body.to_enum(:scan, /\bL_OP_(\w+?)_BODY:/).map { [Regexp.last_match(1), Regexp.last_match.begin(0)] }
      labels = body.to_enum(:scan, /\b(L_\w+):(?!:)/).to_h { [Regexp.last_match(1), Regexp.last_match.begin(0)] }
      region_end = ->(pos) { (starts.map(&:last).select { |s| s > pos }.min || body.bytesize) }

      site_line = ->(abs) { lines.at(abs)[1] }
      restores_in = lambda do |from, to|
        seg = body.byteslice(from, to - from)
        seg.to_enum(:scan, RESTORE).map { site_line.(exec.from + from + Regexp.last_match.begin(0)) }
      end

      # static 関数ごとの restore の所 (その先の static 関数も)
      fn_calls = statics.transform_values do |f|
        text.byteslice(f.from, f.to - f.from).scan(/\b([A-Za-z_]\w*)\s*\(/).flatten.uniq.select { |c| statics.key?(c) && c != f.name }
      end
      fn_restores = statics.transform_values do |f|
        t = text.byteslice(f.from, f.to - f.from)
        t.to_enum(:scan, RESTORE).map { site_line.(f.from + Regexp.last_match.begin(0)) }
      end
      closure = lambda do |names|
        seen = []
        queue = names.dup
        until queue.empty?
          c = queue.shift
          next if seen.include?(c) || c == "mrb_vm_exec"

          seen << c
          queue.concat(fn_calls[c] || [])
        end
        seen
      end
      external = lambda do |seg|
        seg.scan(/\b(mrb_\w+)\s*\(/).flatten.uniq.reject { |c| defined_here.include?(c) }.sort
      end

      covered = []
      rows = ops.map do |name, fmt|
        s = starts.find { |n, _| n == name } or next { op: name, fmt: fmt, line: "-", arena: "(no CASE)", save: "", calls: "", via: "" }

        segs = [[s[1], region_end.(s[1]), "own"]]
        i = 0
        while i < segs.size
          from, to, = segs[i]
          body.byteslice(from, to - from).scan(/goto\s+(L_\w+)\s*;/).flatten.uniq.each do |lab|
            next if lab == "L_END_DISPATCH"

            pos = labels[lab] or next
            next if segs.any? { |f, to, _| pos >= f && pos < to } # もう辿った区間の中の label

            segs << [pos, region_end.(pos), lab]
          end
          i += 1
        end
        seg_text = segs.map { |f, t, _| body.byteslice(f, t - f) }.join("\n")
        sites = segs.flat_map { |f, t, via| restores_in.(f, t).map { |ln| "#{via == 'own' ? '' : "#{via}@"}#{ln}" } }
        callees = closure.(seg_text.scan(/\b([A-Za-z_]\w*)\s*\(/).flatten.uniq.select { |c| statics.key?(c) })
        callees.each { |c| fn_restores[c].each { |ln| sites << "#{c}@#{ln}" } }
        covered.concat(segs.flat_map { |f, t, _| restores_in.(f, t) })
        callees.each { |c| covered.concat(fn_restores[c]) }
        all_text = seg_text + callees.map { |c| text.byteslice(statics[c].from, statics[c].to - statics[c].from) }.join("\n")
        { op: name, fmt: fmt, line: site_line.(exec.from + s[1]), arena: sites.empty? ? "none" : sites.uniq.join(" "),
          save: all_text.match?(SAVE) ? "save" : "", calls: external.(all_text).join(" "),
          via: (segs.map(&:last) - ["own"]).join(" ") }
      end

      # どの命令からも辿れない restore の所 (vm.c の中)。exec の外の関数 (mrb_funcall の中など) も含めて出す
      all_sites = statics.values.flat_map { |f| fn_restores[f.name].map { |ln| [f.name, ln] } }
      all_sites += restores_in.(0, body.bytesize).map { |ln| ["mrb_vm_exec", ln] }
      uncovered = all_sites.reject { |_, ln| covered.include?(ln) }.uniq
      [rows, uncovered]
    end

    def tsv(rows)
      "# 命令の表 (計画 S2-2、rake fpga:v2:inventory が vm.c から作る。手で書かない)。行番号は今の vm.c の目安 (写し元の名前は CASE)\n" \
        "# op<TAB>operand<TAB>vm.c の行<TAB>arena の restore (行、label@行 は goto の先、関数@行 は呼ぶ static 関数の中)<TAB>save<TAB>" \
        "goto で行く label<TAB>呼ぶ vm.c の外の関数\n" +
        rows.map { |r| [r[:op], r[:fmt], r[:line], r[:arena], r[:save], r[:via], r[:calls]].join("\t") }.join("\n") + "\n"
    end
  end
end
