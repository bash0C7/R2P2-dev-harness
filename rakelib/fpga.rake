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
  Dir[File.join(FPGA_RTL_DIR, "**", "*.sv")].sort
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

# Verilator --binary。C++ を書かずに SV だけのテストベンチを実行ファイルにする。
# -Wall の warning は error 扱い (Verilator の既定)。波形は FST。
def fpga_sim_verilator(tb)
  tb, path = fpga_testbench_path(tb)
  mdir = File.join(FPGA_BUILD_DIR, "verilator", tb)
  FileUtils.rm_rf mdir
  FileUtils.mkdir_p mdir
  sh "verilator", "--binary", "--timing", "--assert", "-Wall", "--trace-fst",
     "-j", "0", "--Mdir", mdir, "--top-module", tb, "-o", tb,
     *fpga_rtl_sources, path
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
  sh "iverilog", "-g2012", "-Wall", "-o", vvp, "-s", tb, *fpga_rtl_sources, path
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
  task :test do
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
