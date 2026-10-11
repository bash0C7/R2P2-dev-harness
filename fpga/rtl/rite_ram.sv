`timescale 1ns / 1ps
// rite_core の表 (M9K の形: 同期読み 1 本、書き 1 本)。ra を置いた次の cycle の終わりに q が mem[ra] になる
module rite_ram #(
  parameter int W = 8,
  parameter int D = 64
) (
  input  logic                 clk,
  input  logic                 we,
  input  logic [$clog2(D)-1:0] wa,
  input  logic [W-1:0]         wd,
  input  logic [$clog2(D)-1:0] ra,
  output logic [W-1:0]         q
);
  logic [W-1:0] mem [0:D-1];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q <= mem[ra];
  end
endmodule
