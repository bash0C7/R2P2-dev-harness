// ROM イメージ1本をコアで走らせ、tools/fpga/ref_vm.rb と同じ書式のトレースを書くテストベンチ。
// 合否はここでは出さない。rake fpga:check が参照インタプリタのトレースと突き合わせる。
//
// plusargs:
//   +rom=<hex>    tools/fpga/rom.rb が出した $readmemh ファイル
//   +trace=<out>  トレースの書き出し先
//   +max=<n>      命令数の上限 (既定 20000)
//   +stim=<file>  入力の刺激。1行 "<step> <port> <value>" (10進)。step 番目の命令から port が value になる
//   +dump=<fst>   波形
`timescale 1ns / 1ps
// テストベンチなので、幅合わせ・未使用の出力・negedge での blocking 代入の lint は切る (RTL は -Wall のまま)
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
/* verilator lint_off SYNCASYNCNET */
module mrb_run_tb;
  import mrb_pkg::*;

  localparam int PC_BITS  = 10;
  localparam int NREGS    = 16;
  localparam int MAX_STIM = 256;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [NPORTS-1:0][INT_BITS-1:0] in_val;
  logic [NPORTS-1:0][VAL_BITS-1:0] out_val;
  logic halted, error;

  mrb_soc #(.NREGS(NREGS), .PC_BITS(PC_BITS)) dut (
    .clk, .rst_n, .en(1'b1), .in_val, .out_val, .halted, .error
  );

  always #5 clk = ~clk;

  // ---- 入力の刺激: 今の step に効いている最後の行
  int stim_step [MAX_STIM];
  int stim_port [MAX_STIM];
  int stim_val  [MAX_STIM];
  int nstim = 0;
  int step = 0;

// step が進むたびに明示的に呼ぶ (always_comb の再評価の時期にシミュレータ差があるので頼らない)
task automatic update_inputs();
  for (int p = 0; p < NPORTS; p++) in_val[p] = 0;
  for (int i = 0; i < nstim; i++)
    if (stim_step[i] <= step && stim_port[i] >= 0 && stim_port[i] < NPORTS)
      in_val[stim_port[i]] = stim_val[i];
endtask

  // ---- トレース
  int    fd;
  int    max_steps = 20000;
  string rom_file, trace_file, stim_file, dump;

  // 組み合わせの信号が落ち着いた negedge で見る
  always @(negedge clk) begin
    if (rst_n && dut.core.retire) begin
      $fdisplay(fd, "X %0d %0d %h", step, dut.core.dbg_pc, dut.core.dbg_op);
      if (dut.core.rf_we)
        $fdisplay(fd, "W %0d %0d %0d %h", step, dut.core.rf_waddr,
                  dut.core.rf_wdata[VAL_BITS-1 -: 2], dut.core.rf_wdata[INT_BITS-1:0]);
      if (dut.core.io_we)
        $fdisplay(fd, "O %0d %0d %0d %h", step, dut.core.io_addr,
                  dut.core.io_wdata[VAL_BITS-1 -: 2], dut.core.io_wdata[INT_BITS-1:0]);
      if (dut.core.err) begin
        $fdisplay(fd, "E %0d %0d %h", step, dut.core.dbg_pc, dut.core.dbg_op);
        finish();
      end else if (dut.core.halt) begin
        $fdisplay(fd, "H %0d %0d", step, dut.core.dbg_pc);
        finish();
      end
      step = step + 1;
      update_inputs();
      if (step >= max_steps) begin
        $fdisplay(fd, "L %0d", step);
        finish();
      end
    end
  end

  task automatic finish();
    $fclose(fd);
    $display("PASS mrb_run_tb (%0d steps)", step);
    $finish;
  endtask

  initial begin
    if (!$value$plusargs("rom=%s", rom_file)) $fatal(1, "+rom=<hex> is required");
    if (!$value$plusargs("trace=%s", trace_file)) $fatal(1, "+trace=<file> is required");
    void'($value$plusargs("max=%d", max_steps));
    if ($value$plusargs("dump=%s", dump)) begin
      $dumpfile(dump);
      $dumpvars(0, mrb_run_tb);
    end
    if ($value$plusargs("stim=%s", stim_file)) begin
      int sfd, s, p, v;
      sfd = $fopen(stim_file, "r");
      if (sfd == 0) $fatal(1, "cannot open %s", stim_file);
      while (nstim < MAX_STIM && $fscanf(sfd, "%d %d %d\n", s, p, v) == 3) begin
        stim_step[nstim] = s;
        stim_port[nstim] = p;
        stim_val[nstim]  = v;
        nstim++;
      end
      $fclose(sfd);
    end

    #1; // mrb_soc の initial (ROM を全 bit 1 で埋める) より後に読む
    $readmemh(rom_file, dut.rom);
    update_inputs();
    fd = $fopen(trace_file, "w");
    if (fd == 0) $fatal(1, "cannot open %s", trace_file);

    repeat (2) @(posedge clk);
    #1 rst_n = 1'b1;
  end
endmodule
