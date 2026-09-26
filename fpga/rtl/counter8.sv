// 8bit のフリーランカウンタ。シミュレーション環境 (rake fpga:*) の最初の被験体。
// rst_n は非同期 active-low、en が 1 の cycle だけ数え、255 の次は 0 に折り返す。
`timescale 1ns / 1ps
module counter8 (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  output logic [7:0] count
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) count <= '0;
    else if (en) count <= count + 8'd1;
  end
endmodule
