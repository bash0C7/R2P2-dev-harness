`timescale 1ns / 1ps
// .mrb を置く ROM (M9K)。yosys は初期値付きの M9K を写せないので、rake fpga:synth では中身を数えない (blackbox、M9K は ROM_BYTES / 1024 個)
module rite_rom #(
  parameter int BYTES = 1024,
  parameter     FILE  = ""
) (
  input  logic                     clk,
  input  logic [$clog2(BYTES)-1:0] addr,
  output logic [7:0]               q
);
  logic [7:0] mem [0:BYTES-1];
  initial if (FILE != "") $readmemh(FILE, mem);
  always_ff @(posedge clk) q <= mem[addr];
endmodule
