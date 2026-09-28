# 資源の関所 (rake fpga:synth、docs/superpowers/plans/2026-09-27-fpga-v2.md)。RTL を sv2v で Verilog にし、yosys で数える。
#
# - 記憶: 割り当ての前 ($mem_v2) の大きさ・幅・読み出しポートの数・同期読みかを読み、Cyclone IV の M9K の構成から個数を出す。
#   yosys 0.33 の synth_intel の M9K の割り当ては実験的で個数が合わないので使わない。組み合わせ読みのポートを持つ記憶は M9K に
#   ならず flip-flop と mux になる (ASYNC_OK_BITS より大きければ関所で落とす)
# - 論理: synth_intel -family cycloneiv の cycloneiv_lcell_comb (LUT) と dffeas (FF)。LE はおおよそ max(LUT, FF)。
#   yosys は乗算を DSP に割り当てないので、乗算の module は blackbox にし、呼ぶ側が DSP の数を足す (MULT_DSP)
# - 段数: 汎用の synth -lut 4 (FF は yosys の $_DFF_ で、ltp -noff が区切る) の最長の組み合わせの段数。
#   synth_intel の dffeas は ltp -noff が FF と見なさず、FF を通り抜けて数える (非同期リセットと enable 付きの FF で輪になる) ので使わない。
#   32bit の加算は 7 段 (実測)。100 MHz の目安は「32bit の加算 1 本 + LUT 6 段」(DEPTH_100MHZ)。Quartus のタイミング解析が取れたらそちらを正にする
require "json"
require "open3"
require "tmpdir"

module FpgaSynth
  ROOT = File.expand_path("../..", __dir__)
  # PERIDOT-Air (EP4CE6E22C8N)
  DEVICE = { le: 6272, m9k: 30, mult: 15 }.freeze
  M9K_BITS = 9216
  # M9K の構成 (深さ, 幅)。単純な2ポート (1 読み + 1 書き) のもの
  M9K_SHAPES = [[8192, 1], [4096, 2], [2048, 4], [1024, 9], [512, 18], [256, 36]].freeze
  # 組み合わせ読みでも flip-flop で構わない記憶の大きさ (bit)
  ASYNC_OK_BITS = 512
  # 32bit の加算 (yosys で 23 段) + LUT 6 段 (C8 で LUT と配線 1 段 1 ns 前後、加算は carry chain で 3 ns 前後と見た目安)
  DEPTH_100MHZ = 13
  # 32×32 の乗算 1 本が使う 18×18 の乗算器
  MULT_DSP = 4

  Memory = Struct.new(:name, :size, :width, :rd_ports, :sync_ports, :wr_ports, keyword_init: true) do
    def bits = size * width
    def async? = sync_ports < rd_ports

    # 読み出しポートごとに写しを持つ (1 つの写しは 1 読み + 1 書き) と見た M9K の数
    def m9k
      return 0 if async?
      per = M9K_SHAPES.map { |d, w| (size.to_f / d).ceil * (width.to_f / w).ceil }.min
      per * [rd_ports, 1].max
    end
  end

  Result = Struct.new(:top, :lcells, :ffs, :depth, :memories, :blackboxes, keyword_init: true) do
    def le = [lcells, ffs].max
    def m9k = memories.sum(&:m9k)
    def async_memories = memories.select { |m| m.async? && m.bits > ASYNC_OK_BITS }

    # 予算 {le:, m9k:, mult:, depth:} を超えたもの。空なら関所を通る
    def over(budget)
      out = []
      out << "LE #{le} > #{budget[:le]}" if budget[:le] && le > budget[:le]
      out << "M9K #{m9k} > #{budget[:m9k]}" if budget[:m9k] && m9k > budget[:m9k]
      out << "depth #{depth} > #{budget[:depth]}" if budget[:depth] && depth > budget[:depth]
      async_memories.each { |m| out << "memory #{m.name} (#{m.size}x#{m.width}) has a combinational read port" }
      out
    end
  end

  # rake fpga:synth で数える部品と予算。v2 の部品は段ごとにここへ足す (計画の「予算」の表)
  TARGETS = {
    "counter8" => { files: %w[fpga/rtl/counter8.sv], top: "counter8", budget: { le: 64, m9k: 0, depth: DEPTH_100MHZ } },
    # mruby のバイトコードを直接実行する回路の最初の反復 (Lチカの命令だけ、ROM 1 KB)。予算は PERIDOT-Air の半分まで
    "rite_core" => { files: %w[fpga/rtl/rite_core.sv fpga/rtl/rite_rom.sv], top: "rite_core", blackbox: %w[rite_rom], budget: { le: 3136, m9k: 0, depth: DEPTH_100MHZ } }
  }.freeze

  class Error < StandardError; end

  module_function

  def sv2v
    ENV["SV2V"] || [File.join(ROOT, "build/fpga/tools/sv2v/sv2v"), "sv2v"].find { |c| c.include?("/") ? File.executable?(c) : system("which #{c} > /dev/null 2>&1") }
  end

  def yosys = ENV["YOSYS"] || "yosys"

  def available?
    !sv2v.nil? && system("which #{yosys} > /dev/null 2>&1")
  end

  # files の SystemVerilog を合成して数える。params は top の parameter、blackbox は中身を数えない module の名前
  def run(files:, top:, params: {}, blackbox: [], timeout: 1200)
    raise Error, "sv2v and yosys are required (rake fpga:setup)" unless available?
    Dir.mktmpdir("fpga-synth") do |dir|
      v = File.join(dir, "top.v")
      out, st = Open3.capture2e(sv2v, *files)
      raise Error, "sv2v failed:\n#{out}" unless st.success?
      File.write(v, out)
      read = "read_verilog -sv #{v}; " + blackbox.map { |b| "blackbox #{b}; " }.join +
             params.map { |k, val| "chparam -set #{k} #{val} #{top}; " }.join + "hierarchy -top #{top}; "
      mem_json = File.join(dir, "mem.json")
      yosys!(dir, "#{read}proc; flatten; opt; memory -nomap; opt; write_json #{mem_json}", timeout)
      memories = parse_memories(JSON.parse(File.read(mem_json)))
      stat = File.join(dir, "stat.txt")
      ltp = File.join(dir, "ltp.txt")
      yosys!(dir, "#{read}synth_intel -family cycloneiv -top #{top}; tee -o #{stat} stat", timeout)
      yosys!(dir, "#{read}synth -top #{top} -lut 4; tee -o #{ltp} ltp -noff", timeout)
      s = File.read(stat)
      Result.new(top: top, lcells: s[/cycloneiv_lcell_comb\s+(\d+)/, 1].to_i, ffs: s[/dffeas\s+(\d+)/, 1].to_i,
                 depth: File.read(ltp)[/length=(\d+)/, 1].to_i, memories: memories, blackboxes: blackbox)
    end
  end

  def yosys!(dir, script, timeout)
    log = File.join(dir, "yosys.log")
    ok = system("timeout", timeout.to_s, yosys, "-q", "-l", log, "-p", script, out: File::NULL, err: File::NULL)
    raise Error, "yosys failed or timed out (#{timeout} s):\n#{File.exist?(log) ? File.read(log).lines.last(20).join : ''}" unless ok
  end

  def parse_memories(json)
    json["modules"].values.flat_map do |mod|
      mod["cells"].filter_map do |name, c|
        next unless c["type"] == "$mem_v2"
        pr = c["parameters"]
        rd = bin(pr["RD_PORTS"])
        Memory.new(name: pr["MEMID"].to_s.delete_prefix("\\"), size: bin(pr["SIZE"]), width: bin(pr["WIDTH"]), rd_ports: rd,
                   sync_ports: bin(pr["RD_CLK_ENABLE"]).to_s(2).count("1"), wr_ports: bin(pr["WR_PORTS"]))
      end
    end
  end

  def bin(v) = v.is_a?(Integer) ? v : v.to_i(2)

  # 人が読む形
  def report(r, budget = nil)
    lines = [format("%-16s LE %d (LUT %d, FF %d)  M9K %d  depth %d%s", r.top, r.le, r.lcells, r.ffs, r.m9k, r.depth,
                    r.blackboxes.empty? ? "" : "  (blackbox: #{r.blackboxes.join(', ')})")]
    r.memories.each do |m|
      lines << format("  memory %-12s %6d x %-3d %7d bit  read %d (sync %d)  %s", m.name, m.size, m.width, m.bits, m.rd_ports,
                      m.sync_ports, m.async? ? "combinational read: flip-flops" : "M9K #{m.m9k}")
    end
    if budget
      over = r.over(budget)
      lines << (over.empty? ? "  within budget #{budget}" : "  OVER BUDGET: #{over.join('; ')}")
    end
    lines.join("\n")
  end
end
