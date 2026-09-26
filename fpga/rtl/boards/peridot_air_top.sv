// PERIDOT-Air (Cyclone IV EP4CE6E22C8) の top。mruby の CPU コアを載せ、I/O をピンにつなぐ。
// ピン名は osafune/peridot_air の fpga/air_blank_top (MIT) に合わせる (fpga/boards/peridot_air/)。
//
//   $LED    -> USER_LED[0]   値が true か 0 以外の Integer なら点灯
//   $LED2   -> USER_LED[1]   同上
//   $BUTTON <- D[0]          内部 pull-up。GND に落とす (押す) と 1
//   RESET_N                  基板のリセットスイッチ。コアとI/Oのリセット
//
// CPU は 50MHz の CLOCK_50 で動くが、CE_DIV cycle に1回だけ進める (クロックイネーブル)。
// 既定の 1000 だと 1命令 2 cycle で 25k 命令/秒。fpga/corpus/blink.rb は 1回の反転に 7012 命令なので、
// LED は約 0.28 秒ごとに反転する (シミュレーションで CE_DIV=1 の時 14024 cycle ごとを実測)。
`timescale 1ns / 1ps
module peridot_air_top
  import mrb_pkg::*;
#(
  parameter int    CE_DIV         = 1000,
  parameter bit    LED_ACTIVE_LOW = 1'b0, // 点灯の極性は実機で未確認
  parameter        ROM_FILE       = "" // string。型を付けると Icarus が渡せない
) (
  input  wire       CLOCK_50,
  input  wire       RESET_N,
  input  wire [0:0] D,
  output wire [1:0] USER_LED
);
  // RESET_N を CLOCK_50 に同期させてから使う (解除だけ同期)
  logic [1:0] rst_sync;
  always_ff @(posedge CLOCK_50 or negedge RESET_N)
    if (!RESET_N) rst_sync <= 2'b00;
    else          rst_sync <= {rst_sync[0], 1'b1};
  wire rst_n = rst_sync[1];

  // クロックイネーブル
  localparam int CW = $clog2(CE_DIV + 1);
  logic [CW-1:0] ce_cnt;
  logic          en;
  always_ff @(posedge CLOCK_50 or negedge rst_n)
    if (!rst_n) begin
      ce_cnt <= '0;
      en     <= 1'b0;
    end else if (ce_cnt == CW'(CE_DIV - 1)) begin
      ce_cnt <= '0;
      en     <= 1'b1;
    end else begin
      ce_cnt <= ce_cnt + CW'(1);
      en     <= 1'b0;
    end

  // $BUTTON: D[0] を2段で同期、押す (L) と 1
  logic [1:0] btn_sync;
  always_ff @(posedge CLOCK_50) btn_sync <= {btn_sync[0], ~D[0]};

  logic [NPORTS-1:0][INT_BITS-1:0] in_val;
  logic [NPORTS-1:0][VAL_BITS-1:0] out_val;
  always_comb begin
    in_val = '0;
    in_val[PORT_BUTTON] = {{(INT_BITS-1){1'b0}}, btn_sync[1]};
  end

  /* verilator lint_off PINCONNECTEMPTY */
  mrb_soc #(.ROM_FILE(ROM_FILE)) soc (
    .clk(CLOCK_50), .rst_n, .en, .in_val, .out_val, .halted(), .error()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  function automatic logic lit(input logic [VAL_BITS-1:0] v);
    return v[VAL_BITS-1 -: 2] == TAG_TRUE || (v[VAL_BITS-1 -: 2] == TAG_INT && v[INT_BITS-1:0] != '0);
  endfunction

  assign USER_LED[0] = lit(out_val[PORT_LED]) ^ LED_ACTIVE_LOW;
  assign USER_LED[1] = lit(out_val[PORT_LED2]) ^ LED_ACTIVE_LOW;
endmodule
