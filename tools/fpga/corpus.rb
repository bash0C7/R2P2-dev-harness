# fpga/corpus/*.rb (CPU コアの対象にする Ruby プログラムの集合) の生成物。
#
# 各 <name>.rb から、mrbc で次の2つを作って commit しておく:
#   <name>.mrb   ROM 変換の入力。CI の fpga job は picoruby を取らないので、これを使う
#   <name>.dump  `mrbc -v` の命令行だけ。ROM 変換のテスト (rom_test.rb) が突き合わせる
# 命令の出現表 docs/fpga-opcodes.md もここから作る。
# `rake fpga:corpus` が作り直し、`rake fpga:corpus:check` が最新かを見る (どちらも mrbc が要る)。
require "open3"
require "tmpdir"
require "fileutils"
require_relative "isa"

module FpgaCorpus
  class Error < StandardError; end

  ROOT      = File.expand_path("../..", __dir__)
  DIR       = File.join(ROOT, "fpga", "corpus")
  TABLE     = File.join(ROOT, "docs", "fpga-opcodes.md")
  DUMP_LINE = /\A\s*\d+ \d{3} /

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

  # name => { mrb:, dump: }
  def build_all(mrbc)
    sources.to_h do |src|
      mrb, dump = compile(src, mrbc)
      [File.basename(src, ".rb"), { mrb: mrb, dump: dump }]
    end
  end

  def write(mrbc)
    built = build_all(mrbc)
    built.each do |name, b|
      File.binwrite(File.join(DIR, "#{name}.mrb"), b[:mrb])
      File.write(File.join(DIR, "#{name}.dump"), b[:dump])
    end
    File.write(TABLE, table(built.transform_values { |b| b[:dump] }))
  end

  # 古くなった生成物の名前。空なら最新
  def stale(mrbc)
    built = build_all(mrbc)
    bad = built.flat_map do |name, b|
      mrb = File.join(DIR, "#{name}.mrb")
      dump = File.join(DIR, "#{name}.dump")
      [(mrb unless File.file?(mrb) && File.binread(mrb) == b[:mrb]),
       (dump unless File.file?(dump) && File.read(dump) == b[:dump])]
    end.compact
    bad << TABLE unless File.file?(TABLE) && File.read(TABLE) == table(built.transform_values { |b| b[:dump] })
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
