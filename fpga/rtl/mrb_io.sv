// グローバル変数に割り当てた I/O ポート (tools/fpga/io_map.rb)。
// 出力ポートは最後に SETGV された値を持ち (リセット直後は nil)、GETGV でその値を返す。
// 入力ポートは GETGV で in_val を Integer として返す。
`timescale 1ns / 1ps
module mrb_io
  import mrb_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic [7:0]                        addr,
  output logic [VAL_BITS-1:0]               rdata,
  input  logic                              we,
  input  logic [VAL_BITS-1:0]               wdata,
  input  logic [NPORTS-1:0][INT_BITS-1:0]   in_val,
  output logic [NPORTS-1:0][VAL_BITS-1:0]   out_val
);
  localparam int PB = $clog2(NPORTS);
  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};

  wire [PB-1:0] p = addr[PB-1:0];

  always_comb begin
    if (addr >= 8'(NPORTS)) rdata = V_NIL;
    else if (IN_MASK[p])    rdata = {TAG_INT, in_val[p]};
    else                    rdata = out_val[p];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NPORTS; i++) out_val[i] <= V_NIL;
    end else if (we && addr < 8'(NPORTS) && !IN_MASK[p]) begin
      out_val[p] <= wdata;
    end
  end
endmodule
