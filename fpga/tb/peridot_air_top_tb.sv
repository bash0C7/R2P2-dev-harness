// PERIDOT-Air の top の自己チェック型テストベンチ。
// クロックイネーブルで CPU が遅く回ること、$LED/$LED2 がピンに出ること、D[0] が $BUTTON として読めること、
// RESET_N でやり直すことを見る。
`timescale 1ns / 1ps
/* verilator lint_off WIDTH */
/* verilator lint_off BLKSEQ */
module peridot_air_top_tb;
  import mrb_pkg::*;

  localparam int CE_DIV = 4;

  logic       clk = 1'b0;
  logic       reset_n = 1'b0;
  logic [0:0] d = 1'b1;   // pull-up: 押していない
  wire  [1:0] led;

  peridot_air_top #(.CE_DIV(CE_DIV)) dut (.CLOCK_50(clk), .RESET_N(reset_n), .D(d), .USER_LED(led));

  always #10 clk = ~clk; // 50MHz

  string dump;
  initial begin
    if ($value$plusargs("dump=%s", dump)) begin
      $dumpfile(dump);
      $dumpvars(0, peridot_air_top_tb);
    end
  end

  function automatic logic [47:0] w(logic [7:0] op, logic [7:0] a = 0, logic [15:0] b = 0);
    return {op, a, b, 16'd0};
  endfunction

  // 0: LOADI_1 R1 / 1: SETGV R1 $LED / 2: GETGV R2 $BUTTON / 3: SETGV R2 $LED2
  // 4: LOADI_0 R1 / 5: SETGV R1 $LED / 6: JMP 0
  logic [47:0] prog [7];
  initial begin
    prog[0] = w(OP_LOADI_1, 1);
    prog[1] = w(OP_SETGV, 1, PORT_LED);
    prog[2] = w(OP_GETGV, 2, PORT_BUTTON);
    prog[3] = w(OP_SETGV, 2, PORT_LED2);
    prog[4] = w(OP_LOADI_0, 1);
    prog[5] = w(OP_SETGV, 1, PORT_LED);
    prog[6] = w(OP_JMP, 0, 0);
  end

  // led[0] の立ち上がりの間隔 (cycle)
  int cycles = 0, last_rise = -1, period = -1;
  logic led0_q = 1'b0;
  always @(posedge clk) begin
    cycles++;
    if (led[0] && !led0_q) begin
      if (last_rise >= 0) period = cycles - last_rise;
      last_rise = cycles;
    end
    led0_q = led[0];
  end

  initial begin
    #1;
    for (int i = 0; i < 7; i++) dut.soc.rom[i] = prog[i];
    repeat (3) @(posedge clk);
    reset_n = 1'b1;

    // 1周 7 命令 x 2 cycle x CE_DIV
    repeat (7 * 2 * CE_DIV * 4) @(posedge clk);
    if (period != 7 * 2 * CE_DIV) $fatal(1, "LED period %0d cycles, expected %0d", period, 7 * 2 * CE_DIV);
    if (led[1] !== 1'b0) $fatal(1, "LED2 should be off while D[0] is high");

    d = 1'b0; // 押す
    repeat (7 * 2 * CE_DIV * 2) @(posedge clk);
    if (led[1] !== 1'b1) $fatal(1, "LED2 should follow the button");

    // リセットで LED が消え、また点滅する
    reset_n = 1'b0;
    #1;
    if (led !== 2'b00) $fatal(1, "LEDs should be off in reset, got %b", led);
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    period = -1;
    last_rise = -1;
    repeat (7 * 2 * CE_DIV * 4) @(posedge clk);
    if (period != 7 * 2 * CE_DIV) $fatal(1, "after reset: LED period %0d", period);

    $display("PASS peridot_air_top_tb");
    $finish;
  end
endmodule
