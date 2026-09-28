// rite_core を ROM の .mrb で走らせ、ピンの変化を `pin <ms> <pin> <水準>` の行で出す (host の板のモデルの stderr と同じ形)。
// UNTIL_MS を超える時刻の前で止め、`end halted=<0|1> error=<0|1> op=<> pc=<>` を出す。
//
// +ROM=<file> (1 行 1 バイトの hex、既定 fpga/rite/blink.hex)、+UNTIL_MS=<ms> (既定 2000)。
// +EXPECT=<file> (既定 fpga/rite/blink.pins、host の picoruby が出したピンの列。rake fpga:rite:hex が作る) があれば、
// ピンの列がそれと同じで error が立たなければ PASS。+EXPECT=none で比べない (rake fpga:rite:check が host と比べる)
`timescale 1ns / 1ps
module rite_core_tb;
  localparam int MS_CYCLES = 1000;  // シミュレーションを速くするため 1 ms を 1000 cycle にする (回路の意味は同じ)
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  // テストベンチのクロック生成は blocking で書くのが定石なので、ここだけ Verilator の -Wall を黙らせる
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  logic [31:0] pins, ms_now;
  logic        halted, error;
  logic [7:0]  error_op;
  logic [15:0] error_pc;
  rite_core #(.ROM_BYTES(1024), .MS_CYCLES(MS_CYCLES)) dut (
    .clk, .rst_n, .pins, .ms_now, .halted, .error, .error_op, .error_pc
  );

  string  rom_file, expect_file;
  integer until_ms, fd, n_seen, n_expect, ems, epin, elv;
  logic   bad;
  integer seen_ms [0:255], seen_pin [0:255], seen_lv [0:255];
  logic [31:0] last;
  initial begin
    if (!$value$plusargs("ROM=%s", rom_file)) rom_file = "fpga/rite/blink.hex";
    if (!$value$plusargs("UNTIL_MS=%d", until_ms)) until_ms = 2000;
    if (!$value$plusargs("EXPECT=%s", expect_file)) expect_file = "fpga/rite/blink.pins";
    $readmemh(rom_file, dut.rom.mem);
    n_seen = 0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    last = 32'hFFFF_FFFF;  // 起動の時の水準 (全部入力で pull_down 無し)
    while (!(halted || error || ms_now > until_ms)) begin
      @(posedge clk);
      if (pins !== last) begin
        for (int p = 0; p < 32; p++)
          if (pins[p] !== last[p]) begin
            $display("pin %0d %0d %0d", ms_now, p, pins[p]);
            if (n_seen < 256) begin seen_ms[n_seen] = ms_now; seen_pin[n_seen] = p; seen_lv[n_seen] = 32'(pins[p]); end
            n_seen++;
          end
        last = pins;
      end
    end
    $display("end halted=%0d error=%0d op=%0d pc=%0d", halted, error, error_op, error_pc);
    if (expect_file == "none") $finish;
    bad = error;
    n_expect = 0;
    fd = $fopen(expect_file, "r");
    if (fd == 0) $fatal(1, "no %s", expect_file);
    while ($fscanf(fd, "pin %d %d %d\n", ems, epin, elv) == 3) begin
      if (n_expect >= n_seen || seen_ms[n_expect] != ems || seen_pin[n_expect] != epin || seen_lv[n_expect] != elv) begin
        $display("expected [%0d] pin %0d %0d %0d", n_expect, ems, epin, elv);
        bad = 1;
      end
      n_expect++;
    end
    $fclose(fd);
    if (n_expect != n_seen) begin $display("expected %0d pin changes, got %0d", n_expect, n_seen); bad = 1; end
    if (bad) $fatal(1, "FAIL rite_core_tb");
    $display("PASS rite_core_tb");
    $finish;
  end
endmodule
