// counter8 の自己チェック型テストベンチ。
// 合格なら最後に "PASS <tb名>" を出して $finish、食い違えば $fatal で落とす。
// rake は exit status と PASS 行の両方を見る (docs/spec.md §10)。
`timescale 1ns / 1ps
module counter8_tb;
  logic       clk = 1'b0;
  logic       rst_n = 1'b0;
  logic       en = 1'b0;
  logic [7:0] count;
  logic [7:0] expected;

  counter8 dut (.clk(clk), .rst_n(rst_n), .en(en), .count(count));

  // テストベンチのクロック生成は blocking で書くのが定石なので、ここだけ Verilator の -Wall を黙らせる
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  // +dump=<path> が渡された時だけ波形を書く (rake fpga:sim が FST の置き場を渡す)
  string dump;
  initial begin
    if ($value$plusargs("dump=%s", dump)) begin
      $dumpfile(dump);
      $dumpvars(0, counter8_tb);
    end
  end

  task automatic check(input string what);
    // 4値シミュレータ (Icarus) ではリセット漏れがここで X として見える
    if ($isunknown(count)) $fatal(1, "%s: count is X/Z", what);
    if (count !== expected) $fatal(1, "%s: count=%0d expected=%0d", what, count, expected);
  endtask

  initial begin
    expected = 8'd0;
    repeat (2) @(posedge clk);
    #1 check("in reset");
    rst_n = 1'b1;

    // en=0 の間は止まっている
    repeat (3) @(posedge clk);
    #1 check("hold while en=0");

    // 300 cycle 数えて 255 -> 0 の折り返しを跨ぐ
    en = 1'b1;
    repeat (300) begin
      @(posedge clk);
      expected = expected + 8'd1;
      #1 check("counting");
    end

    // 再び止める
    en = 1'b0;
    repeat (5) @(posedge clk);
    #1 check("hold after count");

    // 非同期リセットで 0 に戻る
    #2 rst_n = 1'b0;
    expected = 8'd0;
    #1 check("async reset");

    $display("PASS counter8_tb");
    $finish;
  end
endmodule
