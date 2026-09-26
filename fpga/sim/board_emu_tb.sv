// PERIDOT-Air のボードエミュレーター。実機の top (fpga/rtl/boards/peridot_air_top.sv) を +mhz のクロック (既定 125MHz) で回し、
// ピンの変化を実時間 (ms) で書く。rake fpga:emu が使う。合否は出さない。
//
// parameter (Verilator の -G で build 時に渡す):
//   CE_DIV      回路に入れる CE_DIV (実機の CE_DIV / TIME_SCALE)
//   MS_CYCLES   sleep_ms の 1ms が回路の何 cycle か (+mhz と TIME_SCALE から rake が決める)
//   TIME_SCALE  ログとボタンの時刻を何倍して実機の時刻とみなすか。CPU は en の cycle でしか進まないので、
//               CE_DIV を 1/k にして時刻を k 倍すれば、ms の精度では実機と同じ挙動になり、k 倍速く回る
// plusargs:
//   +rom=<hex>     ROM イメージ (tools/fpga/mrb2rom.rb の出力)
//   +ms=<n>        何 ms 分回すか (既定 1000)
//   +mhz=<n>       クロック周波数 MHz (既定 125、Raspberry Pi Pico と同じ)。top の CLOCK_50 に入れる
//   +log=<out>     ピンの変化の書き出し先。1行 "<us> <what> <value>"。最後の END 行の value は実行した命令の数。
//                  デバイス (mrb_dev.sv) の GPIO のピンの値の変化は "GPIO<n>"、UART の送信は1バイトずつ "UART"
//   +button=<file> ボタン操作。1行 "<ms> <0|1>" (1 = 押す。D[0] を GND に落とす)
//   +dump=<fst>    波形 (長い時間を回すと大きくなる)
`timescale 1ns / 1ps
/* verilator lint_off WIDTH */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SYNCASYNCNET */
module board_emu_tb;
  parameter int CE_DIV = 1000;
  parameter int TIME_SCALE = 1;
  parameter int MS_CYCLES = 125_000; // 回路の時計で 1ms (実機の) が何 cycle か = MHz * 1000 / TIME_SCALE
  localparam int MAX_BTN = 256;

  logic       clk = 1'b0;
  logic       reset_n = 1'b0;
  logic [0:0] d = 1'b1;
  wire  [1:0] led;

  peridot_air_top #(.CE_DIV(CE_DIV), .MS_CYCLES(MS_CYCLES)) dut (.CLOCK_50(clk), .RESET_N(reset_n), .D(d), .USER_LED(led));

  // シミュレーションでは周波数は時刻のラベルでしかないので、どこまでも上げられる
  real mhz = 125.0;
  initial void'($value$plusargs("mhz=%f", mhz));
  always #(500.0 / mhz) clk = ~clk; // 半周期 ns

  int    fd;
  int    ms = 1000;
  string rom_file, log_file, btn_file, dump;
  int    btn_ms [MAX_BTN];
  int    btn_v  [MAX_BTN];
  int    nbtn = 0;

  // 実機での時刻 (us)
  function automatic longint now_us();
    return $time * TIME_SCALE / 1000;
  endfunction

  // 実行した命令の数 (END 行に書き、参照インタプリタを同じ数だけ回すのに使う)
  longint steps = 0;
  always @(negedge clk) if (dut.soc.core.retire) steps++;

  logic [1:0] led_q = 2'b00;
  bit         first = 1'b1; // リセット解除直後の状態も1回書く
  logic       halted_q = 1'b0, error_q = 1'b0;
  logic [31:0] gpio_q = '0;
  always @(negedge clk) begin
    if (fd != 0 && reset_n) begin
      if (first || led[0] !== led_q[0]) $fdisplay(fd, "%0d LED %0d", now_us(), led[0]);
      if (first || led[1] !== led_q[1]) $fdisplay(fd, "%0d LED2 %0d", now_us(), led[1]);
      // GPIO: 出力にしたピンの値の変化 (入力のピンは外から駆動しないので書かない)
      for (int i = 0; i < 32; i++)
        if (dut.soc.gpio_dir[i] && dut.soc.gpio_level[i] !== gpio_q[i]) $fdisplay(fd, "%0d GPIO%0d %0d", now_us(), i, dut.soc.gpio_level[i]);
      gpio_q = dut.soc.gpio_level;
      if (dut.soc.tx_valid && dut.soc.en) $fdisplay(fd, "%0d UART %0d", now_us(), dut.soc.tx_byte);
      if (dut.soc.halted && !halted_q) $fdisplay(fd, "%0d HALT %0d", now_us(), dut.soc.core.pc);
      if (dut.soc.error && !error_q) $fdisplay(fd, "%0d ERROR %0d", now_us(), dut.soc.core.pc);
      led_q = led;
      first = 1'b0;
      halted_q = dut.soc.halted;
      error_q = dut.soc.error;
    end
  end

  // ボタン: 1ms ごとに表を見る
  initial begin
    #1;
    forever begin
      for (int i = 0; i < nbtn; i++)
        if (btn_ms[i] * 1000 == now_us()) begin
          d = btn_v[i] ? 1'b0 : 1'b1;
          if (fd != 0) $fdisplay(fd, "%0d BUTTON %0d", now_us(), btn_v[i]);
        end
      #(1000000 / TIME_SCALE); // 実機の 1ms
    end
  end

  initial begin
    if (!$value$plusargs("rom=%s", rom_file)) $fatal(1, "+rom=<hex> is required");
    if (!$value$plusargs("log=%s", log_file)) $fatal(1, "+log=<file> is required");
    void'($value$plusargs("ms=%d", ms));
    if ($value$plusargs("dump=%s", dump)) begin
      $dumpfile(dump);
      $dumpvars(0, board_emu_tb);
    end
    if ($value$plusargs("button=%s", btn_file)) begin
      int bfd, t, v;
      bfd = $fopen(btn_file, "r");
      if (bfd == 0) $fatal(1, "cannot open %s", btn_file);
      while (nbtn < MAX_BTN && $fscanf(bfd, "%d %d\n", t, v) == 2) begin
        btn_ms[nbtn] = t;
        btn_v[nbtn]  = v;
        nbtn++;
      end
      $fclose(bfd);
    end
    fd = 0;
    #2;
    $readmemh(rom_file, dut.soc.rom);
    fd = $fopen(log_file, "w");
    if (fd == 0) $fatal(1, "cannot open %s", log_file);
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    #(longint'(ms) * 1000000 / TIME_SCALE);
    $fdisplay(fd, "%0d END %0d", now_us(), steps);
    $fclose(fd);
    $display("PASS board_emu_tb");
    $finish;
  end
endmodule
