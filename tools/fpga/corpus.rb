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
  DUMP_LINE = /\A\s*\d+ \d{3,} / # iseq のバイト位置は 3 桁以上 (1000 バイトを超える irep もある)
  MAX_REGS  = FpgaIsa::RF_SIZE # 1つの irep が使えるレジスタの上限 = レジスタファイルの大きさ
  # プログラムの前に置いて一緒に compile する組み込みメソッド (Ruby で書いたもの)
  PRELUDE   = Dir[File.join(ROOT, "fpga", "prelude", "*.rb")].sort.freeze
  KINDS     = %w[mrb dump hex lst].freeze
  # FPGA 版の gem (fpga/gems/<名前>.rb)。require するか、定数を使う (R2P2 では require しなくても使える) と、
  # プレリュードの後、プログラムの前に置く。名前 -> [file, 使えば入る定数]
  GEMS_DIR  = File.join(ROOT, "fpga", "gems")
  PICORUBY_MRBLIB = "../../vendor/picoruby/mrbgems/picoruby-%s/mrblib/%s.rb" # GEMS_DIR から
  GEMS = {
    "gpio" => ["gpio.rb", %w[GPIO]], "machine" => ["machine.rb", %w[Machine]], "uart" => ["uart.rb", %w[UART]],
    "rng" => ["rng.rb", %w[RNG]], "irq" => ["irq.rb", %w[IRQ]], "pwm" => ["pwm.rb", %w[PWM]], "adc" => ["adc.rb", %w[ADC]],
    "watchdog" => ["watchdog.rb", %w[Watchdog]], "io/console" => ["io_console.rb", %w[STDIN]],
    "i2c" => ["i2c.rb", %w[I2C]], "spi" => ["spi.rb", %w[SPI]], "time" => ["time.rb", %w[Time]], "vram" => ["vram.rb", %w[VRAM]],
    "bdffont" => ["bdffont.rb", %w[BDFFont]], "task" => ["task.rb", %w[Task]],
    # PicoRuby の mrblib をそのまま使う (Ruby だけで書かれた gem)
    "ssd1306" => [format(PICORUBY_MRBLIB, "ssd1306", "ssd1306"), %w[SSD1306]],
    "uc8151" => [format(PICORUBY_MRBLIB, "uc8151", "uc8151"), %w[UC8151]],
    "hcsr04" => [format(PICORUBY_MRBLIB, "hcsr04", "hcsr04"), %w[HCSR04]],
    "rotary_encoder" => [format(PICORUBY_MRBLIB, "rotary_encoder", "rotary_encoder"), %w[RotaryEncoder]],
    # PSG と MIDI (P5e)。psg の C の部分は fpga/gems/psg.rb、Ruby の部分と midibase 系は PicoRuby の mrblib
    "psg" => [["psg.rb", *%w[prs driver midi_controller sound synth].map { |f| format(PICORUBY_MRBLIB, "psg", f) }], %w[PSG]],
    "midibase" => [[*%w[midibase clock parser router session voice_allocator].map { |f| format(PICORUBY_MRBLIB, "midibase", f) },
                    "midibase_fpga.rb"], %w[MIDIBASE]],
    "signal" => ["signal.rb", %w[Signal]], "picorubyvm" => ["picorubyvm.rb", %w[PicoRubyVM ObjectSpace]], "file" => ["file.rb", %w[File]],
    "midibase-mml" => [%w[clock parser sequence player].map { |f| format(PICORUBY_MRBLIB, "midibase-mml", f) }, []],
    "uart-midi" => [[format(PICORUBY_MRBLIB, "uart-midi", "uart-midi")], []]
  }.freeze
  REQUIRE = /^\s*require\s*\(?\s*["']([^"']+)["']/

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

  class UnknownGem < Error; end

  # src が使う gem の file (gem の中の require と定数もたどる)。知らない require は UnknownGem (strict: false なら飛ばす)
  def gem_files(src, strict: true)
    files = []
    seen = []
    visit = lambda do |text|
      gem_names(text).each do |name|
        unless GEMS[name]
          raise UnknownGem, "require '#{name}' is not supported on the FPGA core (#{src})" if strict
          next
        end
        paths = Array(GEMS[name][0]).map { |f| File.expand_path(f, GEMS_DIR) }
        next if seen.include?(paths[0])
        seen << paths[0]
        visit.call(paths.map { |p| File.read(p) }.join("\n"))
        files.concat(paths) # 使う gem を先に (後置の順)
      end
    end
    visit.call(File.read(src))
    files
  end

  # text が require するか、定数を使う gem の名前 (名前の順)
  def gem_names(text)
    names = text.scan(REQUIRE).flatten
    code = text.gsub(/^\s*#.*$/, "") # 行全体の注釈の中の名前 (「ソフト PWM」) は数えない
    GEMS.each { |name, (_, consts)| names << name if consts.any? { |c| code.match?(/\b#{c}\b/) } }
    names.uniq.sort
  end

  # src -> [mrb bytes, dump lines]。プレリュードと gem を前に付けて1つの irep にする
  def compile(src, mrbc, strict: true)
    raise Error, "mrbc not found at #{mrbc}. Run `rake setup` and `rake test:host`, or set MRBC=" unless File.executable?(mrbc)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out.mrb")
      stdout, stderr, st = Open3.capture3(mrbc, "-v", "-o", out, *PRELUDE, *gem_files(src, strict: strict), src)
      raise Error, "mrbc failed on #{src}: #{stderr}" unless st.success?
      # 命令の行と、irep の区切り ("irep"。mrbc のアドレスは毎回違うので捨てる)
      dump = stdout.scrub.lines.filter_map { |l| l.start_with?("irep ") ? "irep\n" : (l =~ DUMP_LINE ? l.strip + "\n" : nil) }
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
    dump.lines.reject { |l| l.start_with?("irep") }.map { |l| l.split[2] }.tally
  end

  def table(dumps)
    counts = dumps.transform_values { |d| op_counts(d) }
    used = counts.values.flat_map(&:keys).uniq
    rows = FpgaIsa::OPS.compact.select { |op| used.include?(op.name) || FpgaIsa.supported?(op.name) }
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
