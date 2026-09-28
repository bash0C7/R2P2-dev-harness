# mruby のバイトコードを直接実行する回路 (fpga/rtl/rite_core.sv、反復 R1) の道具 (rake fpga:rite:*)。
#
# - rom_hex: .rb を host の mrbc で .mrb にし、ROM の $readmemh (1 行 1 バイト、ROM_BYTES まで 00 で埋める) にする
# - sim: Icarus Verilog で fpga/tb/rite_core_tb.sv を走らせ、ピンの変化の列 [[ms, pin, 水準], ...] と終わり方を得る
# - host: 板のモデル入りの host の picoruby (firmware-patches/posix-board-{clock,gpio}.patch) で同じ .rb を走らせ、同じ形の列を得る
# - check: 2 つの列を比べる
require "fileutils"
require "open3"
require "tmpdir"
require_relative "v2/build"

module FpgaRite
  ROOT = FpgaV2::Build::ROOT
  DIR = File.join(ROOT, "fpga", "rite")
  BUILD = File.join(ROOT, "build", "fpga", "rite")
  ROM_BYTES = 1024
  UNTIL_MS = 2000
  PIN_LINE = /\Apin (\d+) (\d+) ([01])\z/
  END_LINE = /\Aend halted=(\d) error=(\d) op=(\d+) pc=(\d+)\z/
  RTL = %w[fpga/rtl/rite_core.sv fpga/rtl/rite_rom.sv].freeze
  TB = "fpga/tb/rite_core_tb.sv".freeze

  Sim = Struct.new(:pins, :halted, :error, :op, :pc, keyword_init: true)
  Result = Struct.new(:name, :host_pins, :sim, keyword_init: true) do
    def ok? = !sim.error && host_pins == sim.pins
  end

  module_function

  def programs = Dir[File.join(DIR, "*.rb")].sort

  def mrb(rb)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "a.mrb")
      o, st = Open3.capture2e(FpgaV2::Build.mrbc, "-o", out, rb)
      raise "mrbc failed: #{o}" unless st.success?
      File.binread(out)
    end
  end

  def rom_hex(rb)
    bytes = mrb(rb).bytes
    raise "#{rb}: .mrb is #{bytes.size} bytes, the ROM holds #{ROM_BYTES}" if bytes.size > ROM_BYTES
    (bytes + [0] * (ROM_BYTES - bytes.size)).map { |b| format("%02x", b) }.join("\n") + "\n"
  end

  def pin_lines(text) = text.lines(chomp: true).filter_map { |l| l.match(PIN_LINE)&.captures&.map(&:to_i) }

  def vvp
    FileUtils.mkdir_p BUILD
    out = File.join(BUILD, "rite_core_tb.vvp")
    srcs = (RTL + [TB]).map { |f| File.join(ROOT, f) }
    unless File.file?(out) && srcs.all? { |s| File.mtime(s) <= File.mtime(out) }
      o, st = Open3.capture2e("iverilog", "-g2012", "-o", out, "-s", "rite_core_tb", *srcs)
      raise "iverilog failed:\n#{o}" unless st.success?
    end
    out
  end

  def sim(hex_path, until_ms: UNTIL_MS)
    o, st = Open3.capture2e("vvp", "-n", vvp, "+ROM=#{hex_path}", "+UNTIL_MS=#{until_ms}", "+EXPECT=none", chdir: ROOT)
    raise "vvp failed:\n#{o}" unless st.success?
    e = o.lines(chomp: true).filter_map { |l| l.match(END_LINE) }.last or raise "no end line:\n#{o}"
    Sim.new(pins: pin_lines(o), halted: e[1] == "1", error: e[2] == "1", op: e[3].to_i, pc: e[4].to_i)
  end

  def host(rb, until_ms: UNTIL_MS, picoruby: FpgaConverter.default_picoruby)
    _out, err, = Open3.capture3({ "FPGA_BOARD_UNTIL_MS" => until_ms.to_s }, picoruby, rb)
    pin_lines(err)
  end

  def check(rb, until_ms: UNTIL_MS)
    FileUtils.mkdir_p BUILD
    hex = File.join(BUILD, "#{File.basename(rb, '.rb')}.hex")
    File.write(hex, rom_hex(rb))
    Result.new(name: File.basename(rb, ".rb"), host_pins: host(rb, until_ms: until_ms), sim: sim(hex, until_ms: until_ms))
  end

  def format_pins(pins) = pins.map { |ms, pin, v| "pin #{ms} #{pin} #{v}" }
end
