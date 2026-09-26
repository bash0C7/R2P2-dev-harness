# fpga/corpus/*.rb (CPU コアの対象にする Ruby プログラムの集合) の生成物。
#
# 各 <name>.rb から次を作って commit しておく:
#   <name>.mrb   mrbc の出力
#   <name>.dump  `mrbc -v` の命令行だけ。ROM 変換のテスト (rom_test.rb) が突き合わせる
#   <name>.hex   PicoRuby で走らせた変換器 (mrb2rom.rb) の ROM イメージ。rake fpga:check が使う
#   <name>.lst   同じく命令一覧
# CI の fpga job は picoruby を取らないので、ここにある .hex を使う。命令の出現表 docs/fpga-opcodes.md もここから作る。
# `rake fpga:corpus` が作り直し、`rake fpga:corpus:check` が最新かを見る (どちらも mrbc と picoruby が要る)。
require "open3"
require "tmpdir"
require "fileutils"
require_relative "converter"

module FpgaCorpus
  class Error < StandardError; end

  ROOT      = File.expand_path("../..", __dir__)
  DIR       = File.join(ROOT, "fpga", "corpus")
  TABLE     = File.join(ROOT, "docs", "fpga-opcodes.md")
  DUMP_LINE = /\A\s*\d+ \d{3} /
  MAX_REGS  = 16 # mrb_core の NREGS
  KINDS     = %w[mrb dump hex lst].freeze

  module_function

  def sources
    Dir[File.join(DIR, "*.rb")].sort
  end

  def names
    sources.map { |s| File.basename(s, ".rb") }
  end

  def default_mrbc
    ENV["MRBC"] || File.join(ROOT, "vendor", "picoruby", "bin", "mrbc")
  end

  # src -> [mrb bytes, dump lines]
  def compile(src, mrbc)
    raise Error, "mrbc not found at #{mrbc}. Run `rake setup` and `rake test:host`, or set MRBC=" unless File.executable?(mrbc)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out.mrb")
      stdout, stderr, st = Open3.capture3(mrbc, "-v", "-o", out, src)
      raise Error, "mrbc failed on #{src}: #{stderr}" unless st.success?
      dump = stdout.lines.grep(DUMP_LINE).map { |l| l.strip + "\n" }
      [File.binread(out), dump.join]
    end
  end

  # name => { "mrb" =>, "dump" =>, "hex" =>, "lst" => }
  def build_all(mrbc, picoruby)
    sources.to_h do |src|
      name = File.basename(src, ".rb")
      mrb, dump = compile(src, mrbc)
      hex, lst = Dir.mktmpdir do |dir|
        paths = %w[in.mrb out.hex out.lst].map { |f| File.join(dir, f) }
        File.binwrite(paths[0], mrb)
        FpgaConverter.run(paths[0], paths[1], paths[2], max_regs: MAX_REGS, picoruby: picoruby)
        [File.read(paths[1]), File.read(paths[2])]
      end
      [name, { "mrb" => mrb, "dump" => dump, "hex" => hex, "lst" => lst }]
    end
  end

  def write(mrbc, picoruby)
    built = build_all(mrbc, picoruby)
    built.each do |name, b|
      KINDS.each { |k| File.binwrite(File.join(DIR, "#{name}.#{k}"), b[k]) }
    end
    File.write(TABLE, table(built.transform_values { |b| b["dump"] }))
  end

  # 古くなった生成物の path。空なら最新
  def stale(mrbc, picoruby)
    built = build_all(mrbc, picoruby)
    bad = []
    built.each do |name, b|
      KINDS.each do |k|
        path = File.join(DIR, "#{name}.#{k}")
        bad << path unless File.file?(path) && File.binread(path) == b[k].b
      end
    end
    bad << TABLE unless File.file?(TABLE) && File.read(TABLE) == table(built.transform_values { |b| b["dump"] })
    bad.map { |p| p.sub("#{ROOT}/", "") }
  end

  def op_counts(dump)
    dump.lines.map { |l| l.split[2] }.tally
  end

  def table(dumps)
    counts = dumps.transform_values { |d| op_counts(d) }
    used = counts.values.flat_map(&:keys).uniq
    rows = FpgaIsa::OPS.select { |op| used.include?(op.name) || FpgaIsa.supported?(op.name) }
    names = dumps.keys
    out = +"# FPGA コアの対応命令と、コーパスでの出現回数\n\n"
    out << "`rake fpga:corpus` が `fpga/corpus/*.rb` の `mrbc -v` から生成する。手で直さない。\n"
    out << "対応 = CPU コア (`fpga/rtl/mrb_core.sv`) と参照インタプリタ (`tools/fpga/ref_vm.rb`) が実行する命令\n"
    out << "(`tools/fpga/isa.rb` の `SUPPORTED`)。意味と決定事項は [spec.md](spec.md) §10。\n\n"
    out << "| op | 番号 | 形式 | 対応 | #{names.join(' | ')} |\n"
    out << "|---|---:|---|---|#{names.map { '---:' }.join('|')}|\n"
    rows.each do |op|
      cells = names.map { |n| counts[n][op.name] || "" }
      out << "| #{op.name} | #{op.num} | #{op.fmt} | #{FpgaIsa.supported?(op.name) ? 'yes' : '**no**'} | #{cells.join(' | ')} |\n"
    end
    out
  end
end
