// PERIDOT-Air (Cyclone IV EP4CE6E22C8) の top: mruby のバイトコードを直接実行する rite_core (反復 R2: Lチカと、ROM の先頭の mruby の mrblib)。
// ピン名は osafune/peridot_air の fpga/air_blank_top (MIT) に合わせる (fpga/boards/peridot_air/)。
//
//   ROM         <- .mrb (host の mrbc で作ったもの、rake fpga:rite:build が rom.hex にする)
//   USER_LED[0] <- ピン LED_PIN の水準 (板のモデルの LED のピン、fpga/rite/blink.rb の 28)
//   USER_LED[1] <- 範囲の外の命令やメソッドに当たって止まった印 (error)
//   RESET_N        基板のリセットスイッチ
//
// CLOCK_50 で 1 ms は 50,000 cycle。点灯の極性 (LED_ACTIVE_LOW) は実機で未確認
`timescale 1ns / 1ps
module peridot_air_rite_top #(
  parameter int ROM_BYTES      = 4096,
  parameter     ROM_FILE       = "",   // string。型を付けると Icarus が渡せない
  parameter int MS_CYCLES      = 50_000,
  parameter int LED_PIN        = 28,
  parameter bit LED_ACTIVE_LOW = 1'b0
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

  logic [31:0] pins, ms_now;
  logic        halted, error;
  logic [7:0]  error_op;
  logic [15:0] error_pc;
  rite_core #(.ROM_BYTES(ROM_BYTES), .ROM_FILE(ROM_FILE), .MS_CYCLES(MS_CYCLES)) core (
    .clk(CLOCK_50), .rst_n(rst_sync[1]), .pins, .ms_now, .halted, .error, .error_op, .error_pc
  );

  assign USER_LED[0] = pins[LED_PIN] ^ LED_ACTIVE_LOW;
  assign USER_LED[1] = error ^ LED_ACTIVE_LOW;

  // D は使わない (次の反復の GPIO の入力)
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused = &{1'b0, D, ms_now, halted, error_op, error_pc};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
