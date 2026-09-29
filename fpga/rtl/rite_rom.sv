`timescale 1ns / 1ps
// .mrb を置く ROM (M9K、読み口 2 本: 1 本は命令と .mrb を読む、もう 1 本は sym の名前を照らす)。
// yosys は初期値付きの M9K を写せないので、rake fpga:synth では中身を数えない (blackbox)
module rite_rom #(
  parameter int BYTES = 4096,
  parameter     FILE  = ""
) (
  input  logic                     clk,
  input  logic [$clog2(BYTES)-1:0] addr,
  output logic [7:0]               q,
  input  logic [$clog2(BYTES)-1:0] addr2,
  output logic [7:0]               q2
);
  logic [7:0] mem [0:BYTES-1];
  initial if (FILE != "") $readmemh(FILE, mem);
  always_ff @(posedge clk) begin
    q  <= mem[addr];
    q2 <= mem[addr2];
  end
endmodule
