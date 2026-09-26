// ROM + CPU コア + I/O (ポート) + デバイス (GPIO、時間、UART、RNG)。シミュレーションのテストベンチと実機の top の両方がこれを置く。
// ROM の空きは全 bit 1 (op 0xff) で、プログラムの外へ出たコアはエラーで止まる。
`timescale 1ns / 1ps
module mrb_soc
  import mrb_pkg::*;
#(
  parameter int    NREGS    = RF_SIZE,
  parameter int    PC_BITS  = 14,
  parameter        ROM_FILE = "" // string。型を付けると Icarus が渡せない
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              en,
  input  logic                              ms_tick,  // 1ms ごとの 1 cycle のパルス (sleep_ms / sleep)
  input  logic [NPORTS-1:0][INT_BITS-1:0]   in_val,
  output logic [NPORTS-1:0][VAL_BITS-1:0]   out_val,
  output logic                              halted,
  output logic                              error,
  // デバイス (mrb_dev.sv)。外からの入力は実機では 0、シミュレーションはテストベンチが刺激から作る
  input  logic [31:0]                       ext_low,
  input  logic [31:0]                       ext_high,
  input  logic [15:0]                       rx_count,
  input  logic [7:0]                        rx_bytes [256],
  output logic [31:0]                       gpio_dir,
  output logic [31:0]                       gpio_out,
  output logic [31:0]                       gpio_level,
  output logic                              tx_valid,
  output logic [7:0]                        tx_byte
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
  logic [15:0]         io_addr;
  logic [VAL_BITS-1:0] io_rdata, io_wdata, port_rdata, dev_rdata;
  logic                io_we, io_re;
  logic [63:0]         vtime;
  // 0x100 から上はデバイス
  wire                 is_dev = io_addr >= 16'h100;
  assign io_rdata = is_dev ? dev_rdata : port_rdata;

  always_ff @(posedge clk) if (en) rom_data <= rom[rom_addr];

  // トレース用の信号はテストベンチが core.* で覗く
  /* verilator lint_off PINCONNECTEMPTY */
  mrb_core #(.NREGS(NREGS), .PC_BITS(PC_BITS)) core (
    .clk, .rst_n, .en, .ms_tick,
    .rom_addr, .rom_data,
    .io_addr, .io_re, .vtime, .io_rdata, .io_we, .io_wdata,
    .halted, .error,
    .retire(), .fetching(), .dbg_pc(), .dbg_op(), .rf_we(), .rf_waddr(), .rf_wdata()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  mrb_io io (
    .clk, .rst_n,
    .addr(io_addr), .rdata(port_rdata), .we(io_we && !is_dev), .wdata(io_wdata),
    .in_val, .out_val
  );

  mrb_dev dev (
    .clk, .rst_n,
    .addr(io_addr), .rdata(dev_rdata), .re(io_re && is_dev), .we(io_we && is_dev), .wdata(io_wdata), .vtime,
    .ext_low, .ext_high, .rx_count, .rx_bytes,
    .gpio_dir, .gpio_out, .gpio_level, .tx_valid, .tx_byte
  );
endmodule
