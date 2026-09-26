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
# fpga/corpus/*.rb が対象のプログラム。.mrb .dump .hex .lst は commit してあり (tools/fpga/corpus.rb)、
# CI の fpga job は picoruby 無しでそれを使う。
#
# .mrb -> ROM の変換器 (tools/fpga/mrb2rom.rb ほか) は PicoRuby で書いてあり、PicoRuby の host VM で走らせる
# (FpgaConverter.run)。rake は起動と、参照インタプリタ (CRuby) やシミュレーションとの受け渡しだけをする。
require_relative "../tools/fpga/converter"
require_relative "../tools/fpga/ref_vm"
require_relative "../tools/fpga/compare"
require_relative "../tools/fpga/corpus"
require_relative "../tools/fpga/gen_pkg"
require_relative "../tools/fpga/quartus"
require_relative "../tools/fpga/emu"

FPGA_SIM_DIR       = File.join(FPGA_DIR, "sim")
FPGA_ROM_DIR       = File.join(FPGA_BUILD_DIR, "rom")
FPGA_CORE_NREGS    = FpgaCorpus::MAX_REGS
FPGA_DEFAULT_STEPS = 20_000
FPGA_BOARD_BUILD   = File.join(FPGA_BUILD_DIR, "peridot_air")

def fpga_rel(path)
  path.sub("#{HARNESS_ROOT}/", "")
end

# .rb (mrbc で compile してから) か .mrb を、PicoRuby の変換器で build/fpga/rom/<name>.hex と .lst にする。
# 返り値は hex の path。
def fpga_rom(src)
  name = File.basename(src, ".*")
  FileUtils.mkdir_p FPGA_ROM_DIR
  mrb = case File.extname(src)
        when ".mrb" then src
        when ".rb"
          out = File.join(FPGA_ROM_DIR, "#{name}.mrb")
          File.binwrite(out, FpgaCorpus.compile(src, FpgaCorpus.default_mrbc).first)
          out
        else raise "#{src}: expected a .rb or .mrb"
        end
  base = File.join(FPGA_ROM_DIR, name)
  msg = FpgaConverter.run(mrb, "#{base}.hex", "#{base}.lst", max_regs: FPGA_CORE_NREGS)
  puts "#{fpga_rel(src)}: #{msg} (picoruby)"
  "#{base}.hex"
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
    fpga_quiet_sh(File.join(mdir, "build.log"),
                  "verilator", "--binary", "--timing", "--assert", "-Wall", "--trace-fst",
                  "-j", "0", "--Mdir", mdir, "--top-module", "mrb_run_tb", "-o", "mrb_run_tb",
                  *fpga_rtl_sources, File.join(FPGA_SIM_DIR, "mrb_run_tb.sv"))
    File.join(mdir, "mrb_run_tb")
  end
end

# PERIDOT-Air のボードエミュレーターで src を ms だけ走らせ、ピンの変化を表示する。
# <name>.buttons があればボタンを押す (その時は参照との突き合わせはしない)。返り値は参照と一致したか。
def fpga_emulate(src, ms:, ce_div:, verbose: true)
  hex = File.extname(src) == ".hex" ? src : fpga_rom(src)
  name = File.basename(src, ".*")
  buttons = File.join(File.dirname(src), "#{name}.buttons")
  buttons = nil unless File.file?(buttons)
  sim_ce, k = FpgaEmu.scale(ce_div, fast: ENV["FPGA_EMU_EXACT"].nil?)

  exe = fpga_board_emu(sim_ce, k)
  FileUtils.mkdir_p FPGA_ROM_DIR
  log = File.join(FPGA_ROM_DIR, "#{name}.emu.log")
  cmd = [exe, "+rom=#{hex}", "+ms=#{ms}", "+log=#{log}"]
  if buttons
    plain = File.join(FPGA_ROM_DIR, "#{name}.buttons")
    File.write(plain, FpgaCompare.read_stim(buttons).map { |r| r.join(" ") + "\n" }.join)
    cmd << "+button=#{plain}"
  end
  out = IO.popen(cmd, err: [:child, :out], &:read)
  raise "board emulator failed:\n#{out}" unless $?.success? && out.include?("PASS board_emu_tb")

  events = FpgaEmu.read_log(log)
  if verbose
    puts "PERIDOT-Air emulation: #{fpga_rel(hex)}, #{ms} ms, CE_DIV=#{ce_div}" +
         (k > 1 ? " (run with CE_DIV=#{sim_ce}, time x#{k}; FPGA_EMU_EXACT=1 for 1:1)" : "")
    puts FpgaEmu.format_events(events)
    unless buttons
      FpgaEmu.periods(events).each { |pin, sec| puts format("  %-4s flips every %.4f s on average", pin, sec) if sec }
    end
  end

  if buttons
    puts "  #{name}: buttons in #{fpga_rel(buttons)}, not compared with the reference interpreter"
    ok = true
  else
    trace = fpga_ref_trace(hex, stim: nil, max: FpgaEmu.steps_for(ms, ce_div))
    results = FpgaEmu.check_against_ref(events, trace, FpgaEmu.window_steps(ms, ce_div))
    results.each { |r_ok, msg| puts "  #{r_ok ? 'ok' : 'FAIL'} #{name} #{msg}" }
    ok = results.all?(&:first)
  end
  puts "log: #{fpga_rel(log)}" if verbose
  ok
end

# fpga/sim/board_emu_tb.sv を CE_DIV と時刻の倍率ごとに build する (parameter は build 時に決まる)
def fpga_board_emu(ce_div, time_scale)
  mdir = File.join(FPGA_BUILD_DIR, "verilator", "board_emu_#{ce_div}_x#{time_scale}")
  exe = File.join(mdir, "board_emu")
  sources = [*fpga_rtl_sources, File.join(FPGA_SIM_DIR, "board_emu_tb.sv")]
  return exe if File.executable?(exe) && sources.all? { |s| File.mtime(s) < File.mtime(exe) }
  FileUtils.rm_rf mdir
  FileUtils.mkdir_p mdir
  fpga_quiet_sh(File.join(mdir, "build.log"),
                "verilator", "--binary", "--timing", "--assert", "-Wall", "-O3", "--trace-fst",
                "-j", "0", "-GCE_DIV=#{ce_div}", "-GTIME_SCALE=#{time_scale}",
                "--Mdir", mdir, "--top-module", "board_emu_tb", "-o", "board_emu", *sources)
  exe
end

# シミュレーションで走らせてトレースを返す。トレースなどは build/fpga/rom/<name>.* に書く
def fpga_sim_trace(hex, name:, stim:, max:, dump: nil)
  FileUtils.mkdir_p FPGA_ROM_DIR
  base = File.join(FPGA_ROM_DIR, name)
  trace = "#{base}.sim.trace"
  cmd = [fpga_runner, "+rom=#{hex}", "+trace=#{trace}", "+max=#{max}"]
  if stim
    # テストベンチの $fscanf はコメント行を読めないので、数字だけにしたものを渡す
    plain = "#{base}.stim"
    File.write(plain, FpgaCompare.read_stim(stim).map { |r| r.join(" ") + "\n" }.join)
    cmd << "+stim=#{plain}"
  end
  cmd << "+dump=#{dump}" if dump
  out = IO.popen(cmd, err: [:child, :out], &:read)
  raise "mrb_run_tb failed on #{hex}:\n#{out}" unless $?.success? && out.include?("PASS mrb_run_tb")
  File.readlines(trace, chomp: true)
end

def fpga_ref_trace(hex, stim:, max:)
  vm = FpgaRefVm.new(FpgaConverter.read_hex(hex), nregs: FPGA_CORE_NREGS, stim: FpgaCompare.read_stim(stim))
  vm.run(max)
end

def fpga_show_outputs(trace)
  names = FpgaIoMap::PORTS.to_h { |p| [p.num, p.name] }
  FpgaCompare.outputs(trace).each { |port, v| puts "  #{names[port] || port} = #{v.inspect}" }
  puts "  (#{trace.last})"
end

namespace :fpga do
  desc "Make a ROM image ($readmemh) from a .rb or .mrb with the PicoRuby converter (e.g. rake fpga:rom[fpga/corpus/blink.mrb])"
  task :rom, [:src] do |_t, args|
    raise "usage: rake fpga:rom[<file.rb|file.mrb>]" unless args[:src]
    hex = fpga_rom(args[:src])
    print File.read(hex.sub(/\.hex\z/, ".lst"))
    puts "rom: #{fpga_rel(hex)}"
  end

  desc "Run a .rb/.mrb on the simulated CPU core and print its I/O (e.g. rake fpga:run[fpga/corpus/counter.mrb])"
  task :run, [:src, :max] do |_t, args|
    raise "usage: rake fpga:run[<file.rb|file.mrb>,<max steps>]" unless args[:src]
    require_fpga_tools!
    hex = fpga_rom(args[:src])
    name = File.basename(hex, ".hex")
    dump = File.join(FPGA_ROM_DIR, "#{name}.fst")
    trace = fpga_sim_trace(hex, name: name, stim: fpga_stim_path(args[:src]),
                                max: (args[:max] || FPGA_DEFAULT_STEPS).to_i, dump: dump)
    fpga_show_outputs(trace)
    puts "trace: #{fpga_rel(File.join(FPGA_ROM_DIR, "#{name}.sim.trace"))}"
    puts "waveform: #{fpga_rel(dump)}"
  end

  desc "Emulate PERIDOT-Air (50MHz, CE_DIV, pins) running a .rb/.mrb/.hex for <ms> ms (e.g. rake fpga:emu[fpga/corpus/blink.mrb,2000])"
  task :emu, [:src, :ms, :ce_div] do |_t, args|
    raise "usage: rake fpga:emu[<file.rb|file.mrb|file.hex>,<ms>,<CE_DIV>]" unless args[:src]
    require_fpga_tools!
    ok = fpga_emulate(args[:src], ms: (args[:ms] || 2000).to_i, ce_div: (args[:ce_div] || 1000).to_i)
    raise "board emulation differs from the reference interpreter" unless ok
  end

  namespace :emu do
    desc "Emulate PERIDOT-Air for every fpga/corpus/*.hex (600 ms, CE_DIV=1000) and compare the LEDs with the reference"
    task :check do
      require_fpga_tools!
      failed = Dir[File.join(FpgaCorpus::DIR, "*.hex")].sort.reject do |hex|
        fpga_emulate(hex, ms: 600, ce_div: 1000, verbose: false)
      end
      raise "board emulation differs from the reference: #{failed.map { |h| File.basename(h) }.join(', ')}" unless failed.empty?
    end
  end

  desc "Run every fpga/corpus/*.hex on the reference interpreter and the simulated core, and compare"
  task :check do
    require_fpga_tools!
    hexes = Dir[File.join(FpgaCorpus::DIR, "*.hex")].sort
    raise "no fpga/corpus/*.hex. Run `rake fpga:corpus`" if hexes.empty?
    failed = []
    hexes.each do |hex|
      name = File.basename(hex, ".hex")
      stim = fpga_stim_path(hex)
      ref = fpga_ref_trace(hex, stim: stim, max: FPGA_DEFAULT_STEPS)
      FileUtils.mkdir_p FPGA_ROM_DIR
      File.write(File.join(FPGA_ROM_DIR, "#{name}.ref.trace"), ref.join("\n") + "\n")
      sim = fpga_sim_trace(hex, name: name, stim: stim, max: FPGA_DEFAULT_STEPS)
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

  desc "Regenerate fpga/corpus/*.{mrb,dump,hex,lst} and docs/fpga-opcodes.md (mrbc and the PicoRuby converter)"
  task :corpus do
    FpgaCorpus.write(FpgaCorpus.default_mrbc, FpgaConverter.default_picoruby)
    puts "wrote #{FpgaCorpus.names.size} program(s) and #{fpga_rel(FpgaCorpus::TABLE)}"
  end

  namespace :corpus do
    desc "Check that fpga/corpus/* and docs/fpga-opcodes.md match mrbc and the PicoRuby converter (needs vendor/picoruby)"
    task :check do
      stale = FpgaCorpus.stale(FpgaCorpus.default_mrbc, FpgaConverter.default_picoruby)
      raise "out of date (run `rake fpga:corpus`): #{stale.join(', ')}" unless stale.empty?
      puts "fpga corpus is up to date"
    end
  end

  desc "Regenerate fpga/rtl/mrb_pkg.sv from tools/fpga/isa.rb and io_map.rb"
  task :gen do
    FpgaGenPkg.write
    puts "wrote #{FpgaGenPkg::PATH.sub("#{HARNESS_ROOT}/", '')}"
  end

  desc "Everything for the FPGA core without a board: Ruby tools, testbenches, reference vs simulation, board emulation"
  task test: ["test:fpga", "fpga:tb", "fpga:check", "fpga:emu:check"]

  # ---- PERIDOT-Air 実機 (issue #10 #11)。合成は Quartus、書き込みは openFPGALoader
  desc "Synthesize for PERIDOT-Air with Quartus (local quartus_sh, or FPGA_QUARTUS_HOST over ssh). e.g. rake fpga:build[fpga/corpus/blink.mrb]"
  task :build, [:src, :ce_div] do |_t, args|
    raise "usage: rake fpga:build[<file.rb|file.mrb>,<CE_DIV>]" unless args[:src]
    hex = fpga_rom(args[:src])
    dir = FpgaQuartus.write_project(FPGA_BOARD_BUILD, hex, ce_div: (args[:ce_div] || 1000).to_i)
    rel = fpga_rel(dir)
    puts "project: #{rel}"

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