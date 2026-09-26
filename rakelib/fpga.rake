# FPGA (mruby ネイティブ CPU、issue #4) の HDL シミュレーション。
#
# fpga/rtl/**/*.sv が回路、fpga/tb/<name>_tb.sv がテストベンチ (top module 名 = file 名)。
# テストベンチは自己チェック型: 合格なら "PASS <tb名>" を出して $finish、
# 食い違えば $fatal で落とす。合否は exit status と PASS 行の両方で見る
# (PASS を出す前に $finish した tb を合格にしないため)。
#
# 合否の主は Verilator (--binary、2値)。Icarus (4値) はリセット漏れの X を見るために回す。
# vendor/picoruby は要らないので、`rake setup` 無しで回る。詳細は docs/spec.md §10。

FPGA_DIR       = File.join(HARNESS_ROOT, "fpga")
FPGA_RTL_DIR   = File.join(FPGA_DIR, "rtl")
FPGA_TB_DIR    = File.join(FPGA_DIR, "tb")
FPGA_BUILD_DIR = File.join(BUILD_DIR, "fpga")

# 必須は verilator と iverilog/vvp。surfer は波形を見る時だけ要る。
FPGA_TOOLS = {
  "verilator" => { required: true,  brew: "verilator",      apt: "verilator" },
  "iverilog"  => { required: true,  brew: "icarus-verilog", apt: "iverilog" },
  "vvp"       => { required: true,  brew: "icarus-verilog", apt: "iverilog" },
  "surfer"    => { required: false, brew: "surfer",         apt: nil }
}.freeze

def fpga_os
  case RbConfig::CONFIG["host_os"]
  when /darwin/ then :mac
  when /linux/  then :linux
  else :other
  end
end

def fpga_tool?(name)
  ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
    path = File.join(dir, name)
    File.file?(path) && File.executable?(path)
  end
end

def fpga_missing_tools(required_only: true)
  FPGA_TOOLS.reject { |name, t| (required_only && !t[:required]) || fpga_tool?(name) }.keys
end

# 足りない道具を入れるコマンド。apt は root でなければ sudo を付ける。
def fpga_install_command(tools)
  case fpga_os
  when :mac
    pkgs = tools.map { |n| FPGA_TOOLS[n][:brew] }.compact.uniq
    pkgs.empty? ? nil : "brew install #{pkgs.join(' ')}"
  when :linux
    pkgs = tools.map { |n| FPGA_TOOLS[n][:apt] }.compact.uniq
    return nil if pkgs.empty?
    sudo = Process.uid.zero? ? "" : "sudo "
    "#{sudo}apt-get install -y #{pkgs.join(' ')}"
  end
end

# Linux の surfer は apt に無い。
FPGA_SURFER_LINUX_HINT = "surfer is not in apt. Get the Linux binary from " \
                         "https://gitlab.com/surfer-project/surfer/-/releases " \
                         "or `cargo install --git https://gitlab.com/surfer-project/surfer surfer`".freeze

def require_fpga_tools!
  missing = fpga_missing_tools
  return if missing.empty?
  hint = fpga_install_command(missing)
  raise "FPGA simulators not found: #{missing.join(', ')}. " +
        (hint ? "Run `rake fpga:setup` (= `#{hint}`)." : "Install Verilator and Icarus Verilog by hand.")
end

def fpga_rtl_sources
  # package は使う側より先にコンパイルに渡す
  Dir[File.join(FPGA_RTL_DIR, "**", "*.sv")].sort_by { |p| [p.end_with?("_pkg.sv") ? 0 : 1, p] }
end

def fpga_testbenches
  Dir[File.join(FPGA_TB_DIR, "*_tb.sv")].sort.map { |p| File.basename(p, ".sv") }
end

def fpga_testbench_path(tb)
  tb = tb.to_s.sub(/\.sv\z/, "")
  path = File.join(FPGA_TB_DIR, "#{tb}.sv")
  unless File.file?(path)
    raise "no testbench #{tb.inspect} in fpga/tb/. Known: #{fpga_testbenches.join(', ')}"
  end
  [tb, path]
end

# 走らせて、exit status と PASS 行の両方で判定する。出力はそのまま流す。
def fpga_run_and_judge(tb, sim, cmd)
  out = +""
  IO.popen(cmd, err: [:child, :out]) do |io|
    io.each_line do |line|
      print line
      out << line
    end
  end
  status = $?
  passed = status.success? && out.lines.any? { |l| l.strip == "PASS #{tb}" }
  unless passed
    # Verilator の $fatal は abort() なので exit code ではなく signal で返る
    why = if status.success? then "no \"PASS #{tb}\" line"
          elsif status.exitstatus then "exit #{status.exitstatus}"
          else "signal #{status.termsig}"
          end
    raise "FAIL #{tb} (#{sim}): #{why}"
  end
  puts "ok #{tb} (#{sim})"
end

# コンパイラの出力 (make の行、Icarus の "sorry" 等) は log に落とし、失敗した時だけ見せる。
def fpga_quiet_sh(log, *cmd)
  ok = system(*cmd, out: log, err: [:child, :out])
  raise "#{cmd.first} failed (log: #{log.sub("#{HARNESS_ROOT}/", "")}):\n#{File.read(log)}" unless ok
end

# Verilator --binary。C++ を書かずに SV だけのテストベンチを実行ファイルにする。
# -Wall の warning は error 扱い (Verilator の既定)。波形は FST。
def fpga_sim_verilator(tb)
  tb, path = fpga_testbench_path(tb)
  mdir = File.join(FPGA_BUILD_DIR, "verilator", tb)
  FileUtils.rm_rf mdir
  FileUtils.mkdir_p mdir
  fpga_quiet_sh(File.join(mdir, "build.log"),
                "verilator", "--binary", "--timing", "--assert", "-Wall", "--trace-fst",
                "-j", "0", "--Mdir", mdir, "--top-module", tb, "-o", tb,
                *fpga_rtl_sources, path)
  dump = File.join(FPGA_BUILD_DIR, "#{tb}.fst")
  fpga_run_and_judge(tb, "verilator", [File.join(mdir, tb), "+dump=#{dump}"])
  puts "waveform: #{dump.sub("#{HARNESS_ROOT}/", '')}"
end

# Icarus Verilog。4値なので、リセットされていない register が X のまま見える。
def fpga_sim_icarus(tb)
  tb, path = fpga_testbench_path(tb)
  dir = File.join(FPGA_BUILD_DIR, "icarus")
  FileUtils.mkdir_p dir
  vvp = File.join(dir, "#{tb}.vvp")
  fpga_quiet_sh(File.join(dir, "#{tb}.build.log"), "iverilog", "-g2012", "-Wall", "-o", vvp, "-s", tb, *fpga_rtl_sources, path)
  dump = File.join(FPGA_BUILD_DIR, "#{tb}.icarus.fst")
  fpga_run_and_judge(tb, "icarus", ["vvp", "-n", vvp, "-fst", "+dump=#{dump}"])
  puts "waveform: #{dump.sub("#{HARNESS_ROOT}/", '')}"
end

namespace :fpga do
  desc "Check that the FPGA simulators (Verilator, Icarus Verilog) and Surfer are installed"
  task :doctor do
    FPGA_TOOLS.each do |name, t|
      state = fpga_tool?(name) ? "ok" : (t[:required] ? "MISSING" : "missing (optional, waveform viewer)")
      puts format("%-10s %s", name, state)
    end
    puts `verilator --version`.strip if fpga_tool?("verilator")
    puts `iverilog -V 2>&1`.lines.first.to_s.strip if fpga_tool?("iverilog")
    puts FPGA_SURFER_LINUX_HINT if fpga_os == :linux && !fpga_tool?("surfer")
    require_fpga_tools!
  end

  desc "Install the FPGA simulators (brew on macOS, apt-get on Linux)"
  task :setup do
    missing = fpga_missing_tools(required_only: false)
    cmd = fpga_install_command(missing)
    if cmd
      sh "#{'sudo ' unless Process.uid.zero?}apt-get update" if fpga_os == :linux
      sh cmd
    elsif missing.any? { |n| FPGA_TOOLS[n][:required] }
      raise "don't know how to install #{missing.join(', ')} on #{RbConfig::CONFIG['host_os']}"
    end
    puts FPGA_SURFER_LINUX_HINT if fpga_os == :linux && !fpga_tool?("surfer")
    Rake::Task["fpga:doctor"].invoke
  end

  desc "Run one testbench with Verilator (e.g. rake fpga:sim[counter8_tb])"
  task :sim, [:tb] do |_t, args|
    raise "usage: rake fpga:sim[<testbench>]. Known: #{fpga_testbenches.join(', ')}" unless args[:tb]
    require_fpga_tools!
    fpga_sim_verilator(args[:tb])
  end

  namespace :sim do
    desc "Run one testbench with Icarus Verilog (4-state, shows X from missing resets)"
    task :icarus, [:tb] do |_t, args|
      raise "usage: rake fpga:sim:icarus[<testbench>]. Known: #{fpga_testbenches.join(', ')}" unless args[:tb]
      require_fpga_tools!
      fpga_sim_icarus(args[:tb])
    end
  end

  desc "Run every fpga/tb/*_tb.sv with Verilator and Icarus Verilog"
  task :tb do
    require_fpga_tools!
    tbs = fpga_testbenches
    raise "no testbenches in fpga/tb/" if tbs.empty?
    failed = []
    tbs.each do |tb|
      %w[verilator icarus].each do |sim|
        puts "\n=== #{tb} (#{sim}) ==="
        begin
          sim == "verilator" ? fpga_sim_verilator(tb) : fpga_sim_icarus(tb)
        rescue StandardError => e
          warn e.message
          failed << "#{tb} (#{sim})"
        end
      end
    end
    raise "fpga testbenches failed: #{failed.join(', ')}" unless failed.empty?
    puts "\nall #{tbs.size} testbench(es) passed on verilator and icarus"
  end
end

# ---- mruby バイトコードを実行する CPU コア (issue #6 #7 #8 #9)
#
# fpga/corpus/*.rb が対象のプログラム。.mrb と .dump は commit してあり (tools/fpga/corpus.rb)、
# CI の fpga job は picoruby 無しでそれを使う。
require_relative "../tools/fpga/isa"
require_relative "../tools/fpga/rom"
require_relative "../tools/fpga/ref_vm"
require_relative "../tools/fpga/compare"
require_relative "../tools/fpga/corpus"
require_relative "../tools/fpga/gen_pkg"
require_relative "../tools/fpga/quartus"

FPGA_SIM_DIR      = File.join(FPGA_DIR, "sim")
FPGA_ROM_DIR      = File.join(FPGA_BUILD_DIR, "rom")
FPGA_CORE_NREGS   = 16
FPGA_DEFAULT_STEPS = 20_000
FPGA_BOARD_BUILD  = File.join(FPGA_BUILD_DIR, "peridot_air")

# .rb (mrbc でその場で compile) か .mrb を ROM イメージにして build/fpga/rom/ に書く。
def fpga_rom(src)
  name = File.basename(src, ".*")
  bin = case File.extname(src)
        when ".mrb" then File.binread(src)
        when ".rb"  then FpgaCorpus.compile(src, FpgaCorpus.default_mrbc).first
        else raise "#{src}: expected a .rb or .mrb"
        end
  image = FpgaRom.from_binary(bin, source: src.sub("#{HARNESS_ROOT}/", ""), max_regs: FPGA_CORE_NREGS)
  FileUtils.mkdir_p FPGA_ROM_DIR
  hex = File.join(FPGA_ROM_DIR, "#{name}.hex")
  File.write(hex, image.hex)
  File.write(File.join(FPGA_ROM_DIR, "#{name}.lst"), image.listing)
  [image, hex]
end

# プログラムの入力の刺激: <src と同じ場所>/<name>.stim
def fpga_stim_path(src)
  path = File.join(File.dirname(src), "#{File.basename(src, '.*')}.stim")
  File.file?(path) ? path : nil
end

# fpga/sim/mrb_run_tb.sv を Verilator で1回だけ build する
def fpga_runner
  @fpga_runner ||= begin
    mdir = File.join(FPGA_BUILD_DIR, "verilator", "mrb_run_tb")
    FileUtils.rm_rf mdir
    FileUtils.mkdir_p mdir
    log = File.join(mdir, "build.log")
    ok = system("verilator", "--binary", "--timing", "--assert", "-Wall", "--trace-fst",
                "-j", "0", "--Mdir", mdir, "--top-module", "mrb_run_tb", "-o", "mrb_run_tb",
                *fpga_rtl_sources, File.join(FPGA_SIM_DIR, "mrb_run_tb.sv"),
                out: log, err: [:child, :out])
    raise "verilator failed to build mrb_run_tb:\n#{File.read(log)}" unless ok
    File.join(mdir, "mrb_run_tb")
  end
end

# シミュレーションで走らせてトレースを返す
def fpga_sim_trace(hex, stim:, max:, dump: nil)
  trace = hex.sub(/\.hex\z/, ".sim.trace")
  cmd = [fpga_runner, "+rom=#{hex}", "+trace=#{trace}", "+max=#{max}"]
  if stim
    # テストベンチの $fscanf はコメント行を読めないので、数字だけにしたものを渡す
    plain = hex.sub(/\.hex\z/, ".stim")
    File.write(plain, FpgaCompare.read_stim(stim).map { |r| r.join(" ") + "\n" }.join)
    cmd << "+stim=#{plain}"
  end
  cmd << "+dump=#{dump}" if dump
  out = IO.popen(cmd, err: [:child, :out], &:read)
  raise "mrb_run_tb failed on #{hex}:\n#{out}" unless $?.success? && out.include?("PASS mrb_run_tb")
  File.readlines(trace, chomp: true)
end

def fpga_ref_trace(image, stim:, max:)
  vm = FpgaRefVm.new(image.words.map(&:value), nregs: FPGA_CORE_NREGS, stim: FpgaCompare.read_stim(stim))
  vm.run(max)
end

def fpga_show_outputs(trace)
  names = FpgaIoMap::PORTS.to_h { |p| [p.num, p.name] }
  FpgaCompare.outputs(trace).each { |port, v| puts "  #{names[port] || port} = #{v.inspect}" }
  puts "  (#{trace.last})"
end

namespace :fpga do
  desc "Make a ROM image ($readmemh) from a .rb or .mrb (e.g. rake fpga:rom[fpga/corpus/blink.rb])"
  task :rom, [:src] do |_t, args|
    raise "usage: rake fpga:rom[<file.rb|file.mrb>]" unless args[:src]
    image, hex = fpga_rom(args[:src])
    print image.listing
    puts "rom: #{hex.sub("#{HARNESS_ROOT}/", '')} (#{image.words.size} words, nregs #{image.nregs})"
  end

  desc "Run a .rb/.mrb on the simulated CPU core and print its I/O (e.g. rake fpga:run[fpga/corpus/counter.rb])"
  task :run, [:src, :max] do |_t, args|
    raise "usage: rake fpga:run[<file.rb|file.mrb>,<max steps>]" unless args[:src]
    require_fpga_tools!
    _image, hex = fpga_rom(args[:src])
    dump = hex.sub(/\.hex\z/, ".fst")
    trace = fpga_sim_trace(hex, stim: fpga_stim_path(args[:src]), max: (args[:max] || FPGA_DEFAULT_STEPS).to_i, dump: dump)
    fpga_show_outputs(trace)
    puts "trace: #{hex.sub(/\.hex\z/, '.sim.trace').sub("#{HARNESS_ROOT}/", '')}"
    puts "waveform: #{dump.sub("#{HARNESS_ROOT}/", '')}"
  end

  desc "Run every fpga/corpus/*.mrb on the reference interpreter and the simulated core, and compare"
  task :check do
    require_fpga_tools!
    mrbs = Dir[File.join(FpgaCorpus::DIR, "*.mrb")].sort
    raise "no fpga/corpus/*.mrb. Run `rake fpga:corpus`" if mrbs.empty?
    failed = []
    mrbs.each do |mrb|
      name = File.basename(mrb, ".mrb")
      image, hex = fpga_rom(mrb)
      stim = fpga_stim_path(mrb)
      ref = fpga_ref_trace(image, stim: stim, max: FPGA_DEFAULT_STEPS)
      File.write(hex.sub(/\.hex\z/, ".ref.trace"), ref.join("\n") + "\n")
      sim = fpga_sim_trace(hex, stim: stim, max: FPGA_DEFAULT_STEPS)
      r = FpgaCompare.compare(ref, sim)
      if r.ok
        puts format("ok %-10s %5d I/O writes, %s", name, r.io_count, r.ending)
      else
        puts "FAIL #{name}\n#{r.message}"
        failed << name
      end
    end
    raise "reference and simulation differ: #{failed.join(', ')} (traces in build/fpga/rom/)" unless failed.empty?
  end

  desc "Regenerate fpga/corpus/*.mrb, *.dump and docs/fpga-opcodes.md with mrbc"
  task :corpus do
    FpgaCorpus.write(FpgaCorpus.default_mrbc)
    puts "wrote #{FpgaCorpus.names.size} program(s) and #{FpgaCorpus::TABLE.sub("#{HARNESS_ROOT}/", '')}"
  end

  namespace :corpus do
    desc "Check that fpga/corpus/*.mrb, *.dump and docs/fpga-opcodes.md match mrbc (needs vendor/picoruby)"
    task :check do
      stale = FpgaCorpus.stale(FpgaCorpus.default_mrbc)
      raise "out of date (run `rake fpga:corpus`): #{stale.join(', ')}" unless stale.empty?
      puts "fpga corpus is up to date"
    end
  end

  desc "Regenerate fpga/rtl/mrb_pkg.sv from tools/fpga/isa.rb and io_map.rb"
  task :gen do
    FpgaGenPkg.write
    puts "wrote #{FpgaGenPkg::PATH.sub("#{HARNESS_ROOT}/", '')}"
  end

  desc "Everything for the FPGA core without a board: Ruby tools, testbenches, reference vs simulation"
  task test: ["test:fpga", "fpga:tb", "fpga:check"]

  # ---- PERIDOT-Air 実機 (issue #10 #11)。合成は Quartus、書き込みは openFPGALoader
  desc "Synthesize for PERIDOT-Air with Quartus (local quartus_sh, or FPGA_QUARTUS_HOST over ssh). e.g. rake fpga:build[fpga/corpus/blink.mrb]"
  task :build, [:src, :ce_div] do |_t, args|
    raise "usage: rake fpga:build[<file.rb|file.mrb>,<CE_DIV>]" unless args[:src]
    image, _hex = fpga_rom(args[:src])
    dir = FpgaQuartus.write_project(FPGA_BOARD_BUILD, image, ce_div: (args[:ce_div] || 1000).to_i)
    rel = dir.sub("#{HARNESS_ROOT}/", "")
    puts "project: #{rel} (#{image.words.size} words from #{args[:src]})"

    host = ENV["FPGA_QUARTUS_HOST"]
    if fpga_tool?("quartus_sh")
      FileUtils.cd(dir) { sh FpgaQuartus.compile_script }
    elsif host
      remote = ENV["FPGA_QUARTUS_DIR"] || "r2p2-fpga-build"
      sh "rsync", "-a", "--delete", "#{dir}/", "#{host}:#{remote}/"
      sh "ssh", host, "cd #{remote.shellescape} && #{FpgaQuartus.compile_script}"
      sh "rsync", "-a", "#{host}:#{remote}/output_files/", File.join(dir, "output_files/")
    else
      raise "Quartus is not here. Put quartus_sh on PATH, or set FPGA_QUARTUS_HOST=<ssh host> " \
            "(a Linux VM with Quartus Lite; docs/spec.md §10). The project is ready in #{rel}"
    end

    summary = FpgaQuartus.fit_summary(dir)
    puts summary ? summary.join("\n") : "no fit summary in #{rel}/output_files"
    puts "svf: #{FpgaQuartus.svf_path(dir).sub("#{HARNESS_ROOT}/", '')}"
  end

  desc "Write the last fpga:build into PERIDOT-Air's SRAM over USB-Blaster with openFPGALoader (lost at power off)"
  task :flash do
    svf = FpgaQuartus.svf_path(FPGA_BOARD_BUILD)
    raise "no #{svf.sub("#{HARNESS_ROOT}/", '')}. Run `rake fpga:build[...]` first" unless File.file?(svf)
    unless fpga_tool?("openFPGALoader")
      raise "openFPGALoader not found. `brew install openfpgaloader` (macOS) / `apt-get install openfpgaloader` (Linux)"
    end
    sh "openFPGALoader", "-c", ENV["FPGA_CABLE"] || "usb-blaster", svf
  end
end

namespace :test do
  desc "Run the FPGA Ruby tools' tests (tools/fpga, no simulator needed)"
  task :fpga do
    Dir[File.join(HARNESS_ROOT, "tools", "fpga", "*_test.rb")].sort.each do |test_file|
      ruby test_file
    end
  end
end