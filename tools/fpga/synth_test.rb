require_relative "test_helper"
require_relative "synth"

class FpgaSynthTest < Minitest::Test
  SV = <<~SV
    module sync_ram(input logic clk, we, input logic [9:0] wa, ra, input logic [35:0] d, output logic [35:0] q);
      logic [35:0] m [1024];
      always_ff @(posedge clk) begin if (we) m[wa] <= d; q <= m[ra]; end
    endmodule
    module async_ram(input logic clk, we, input logic [7:0] wa, ra, input logic [67:0] d, output logic [67:0] q);
      logic [67:0] m [256];
      always_ff @(posedge clk) if (we) m[wa] <= d;
      assign q = m[ra];
    endmodule
    module add32(input logic clk, input logic [31:0] a, b, output logic [31:0] y);
      logic [31:0] ra, rb;
      always_ff @(posedge clk) begin ra <= a; rb <= b; y <= ra + rb; end
    endmodule
    module mul32(input logic [31:0] a, b, output logic [63:0] y);
      assign y = a * b;
    endmodule
    module uses_mul(input logic clk, input logic [31:0] a, b, output logic [63:0] y);
      logic [63:0] p;
      mul32 m(.a(a), .b(b), .y(p));
      always_ff @(posedge clk) y <= p;
    endmodule
  SV

  def setup
    skip "sv2v と yosys が無い (rake fpga:setup)" unless FpgaSynth.available?
    @dir = Dir.mktmpdir
    @sv = File.join(@dir, "t.sv")
    File.write(@sv, SV)
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # 同期読みの 1024 x 36 は M9K 4 個 (1024 x 9 を 4 本)。flip-flop にならない
  def test_sync_memory_counts_m9k
    r = FpgaSynth.run(files: [@sv], top: "sync_ram")
    m = r.memories.first
    assert_equal [1024, 36, 1, 1], [m.size, m.width, m.rd_ports, m.sync_ports]
    assert_equal 4, r.m9k
    assert_empty r.over(FpgaSynth::DEVICE)
  end

  # 組み合わせ読みの大きな記憶は関所で落ちる
  def test_async_memory_fails_the_gate
    r = FpgaSynth.run(files: [@sv], top: "async_ram")
    assert r.memories.first.async?
    assert_equal 0, r.m9k
    assert_match(/combinational read/, r.over(FpgaSynth::DEVICE).join)
  end

  # 32bit の加算は LUT 1 本の ripple (yosys は carry chain を使わない)。段数の目安の元
  def test_adder_depth_is_the_depth_unit
    r = FpgaSynth.run(files: [@sv], top: "add32")
    assert_equal 96, r.ffs
    assert_operator r.depth, :<=, FpgaSynth::DEPTH_100MHZ
    assert_empty r.over(le: 200, depth: FpgaSynth::DEPTH_100MHZ)
  end

  # 乗算の module は blackbox にして数えない (DSP に当たる)
  def test_blackbox_leaves_multiplier_out
    r = FpgaSynth.run(files: [@sv], top: "uses_mul", blackbox: ["mul32"])
    assert_operator r.lcells, :<, 100
    assert_equal ["mul32"], r.blackboxes
  end
end
