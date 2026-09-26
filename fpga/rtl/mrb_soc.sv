// ROM + CPU コア + I/O。シミュレーションのテストベンチと実機の top の両方がこれを置く。
// ROM の空きは全 bit 1 (op 0xff) で、プログラムの外へ出たコアはエラーで止まる。
`timescale 1ns / 1ps
module mrb_soc
  import mrb_pkg::*;
#(
  parameter int    NREGS    = RF_SIZE,
  parameter int    PC_BITS  = 13,
  parameter        ROM_FILE = "" // string。型を付けると Icarus が渡せない
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              en,
  input  logic                              ms_tick,  // 1ms ごとの 1 cycle のパルス (sleep_ms / sleep)
  input  logic [NPORTS-1:0][INT_BITS-1:0]   in_val,
  output logic [NPORTS-1:0][VAL_BITS-1:0]   out_val,
  output logic                              halted,
  output logic                              error
);
  logic [47:0] rom [2**PC_BITS];

  // 実機 (Quartus) では ROM_FILE に ROM の全語を埋めたファイルを渡す (rake fpga:build が全 bit 1 で埋める)。
  // シミュレーションでは ROM_FILE を空にし、テストベンチが後から書く
  initial begin
    if (ROM_FILE != "") $readmemh(ROM_FILE, rom);
    else for (int i = 0; i < 2**PC_BITS; i++) rom[i] = '1;
  end

  logic [PC_BITS-1:0]  rom_addr;
  logic [47:0]         rom_data;
  logic [7:0]          io_addr;
  logic [VAL_BITS-1:0] io_rdata, io_wdata;
  logic                io_we;

  always_ff @(posedge clk) if (en) rom_data <= rom[rom_addr];

  // トレース用の信号はテストベンチが core.* で覗く
  /* verilator lint_off PINCONNECTEMPTY */
  mrb_core #(.NREGS(NREGS), .PC_BITS(PC_BITS)) core (
    .clk, .rst_n, .en, .ms_tick,
    .rom_addr, .rom_data,
    .io_addr, .io_rdata, .io_we, .io_wdata,
    .halted, .error,
    .retire(), .dbg_pc(), .dbg_op(), .rf_we(), .rf_waddr(), .rf_wdata()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  mrb_io io (
    .clk, .rst_n,
    .addr(io_addr), .rdata(io_rdata), .we(io_we), .wdata(io_wdata),
    .in_val, .out_val
  );
endmodule
