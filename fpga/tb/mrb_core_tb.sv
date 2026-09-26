// mrb_core の命令ごとの自己チェック型テストベンチ。
// 小さなプログラムを ROM に直接書き、止まるまで回して、レジスタ・I/O・停止状態を見る。
// 対応命令 (tools/fpga/isa.rb の SUPPORTED) のすべてを少なくとも1回ずつ通す。
`timescale 1ns / 1ps
// テストベンチでは定数の幅合わせは邪魔なだけなので、幅の lint はこの file だけ切る (RTL は -Wall のまま)
/* verilator lint_off WIDTH */
module mrb_core_tb;
  import mrb_pkg::*;

  localparam int PC_BITS = 6;
  localparam int NREGS   = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [NPORTS-1:0][INT_BITS-1:0] in_val = '0;
  logic [NPORTS-1:0][VAL_BITS-1:0] out_val;
  logic halted, error;

  mrb_soc #(.NREGS(NREGS), .PC_BITS(PC_BITS)) dut (
    .clk, .rst_n, .en(1'b1), .ms_tick(1'b1), .in_val, .out_val, .halted, .error
  );

  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  string dump;
  initial begin
    if ($value$plusargs("dump=%s", dump)) begin
      $dumpfile(dump);
      $dumpvars(0, mrb_core_tb);
    end
  end

  // ---- プログラムを組む
  logic [47:0] prog [$];
  string       name;
  int          npass = 0;
  int          cycles = 0;
  int          gcs = 0;
  logic        last_space = 1'b0;
  int          base_cycles = 0;

  function automatic logic [47:0] w(logic [7:0] op, logic [7:0] a = 0, logic [15:0] b = 0, logic [15:0] c = 0);
    return {op, a, b, c};
  endfunction

  task automatic begin_test(input string n);
    name = n;
    prog.delete();
  endtask

  task automatic run();
    #1; // mrb_soc の initial (ROM を全 bit 1 で埋める) より後に書く
    for (int i = 0; i < 2**PC_BITS; i++) dut.rom[i] = (i < prog.size()) ? prog[i] : '1;
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    #1 rst_n = 1'b1;
    cycles = 0;
    gcs    = 0;
    last_space = 1'b0;
    for (int i = 0; i < 100000 && !halted && !error; i++) begin
      @(posedge clk);
      cycles++;
      if (dut.core.space != last_space) gcs++; // GC の回数 (使う半分が入れ替わった回数)
      last_space = dut.core.space;
    end
    #1;
  endtask

  function automatic logic [VAL_BITS-1:0] vint(input int v);
    return {TAG_INT, 32'(v)};
  endfunction

  localparam logic [VAL_BITS-1:0] VNIL   = {TAG_NIL, 32'd0};
  localparam logic [VAL_BITS-1:0] VTRUE  = {TAG_TRUE, 32'd0};
  localparam logic [VAL_BITS-1:0] VFALSE = {TAG_FALSE, 32'd0};

  task automatic expect_val(input string what, input logic [VAL_BITS-1:0] got, input logic [VAL_BITS-1:0] v);
    if (got !== v)
      $fatal(1, "%s: %s = tag %0d val %0d, expected tag %0d val %0d", name, what,
             got[VAL_BITS-1 -: TAG_BITS], $signed(got[INT_BITS-1:0]), v[VAL_BITS-1 -: TAG_BITS], $signed(v[INT_BITS-1:0]));
  endtask
  
  task automatic expect_reg(input int r, input logic [VAL_BITS-1:0] v);
    expect_val($sformatf("R%0d", r), dut.core.regs[r], v);
  endtask
  
  task automatic expect_out(input int p, input logic [VAL_BITS-1:0] v);
    expect_val($sformatf("port %0d", p), out_val[p], v);
  endtask
  
  task automatic expect_halt();
    if (!halted || error) $fatal(1, "%s: expected halt (halted=%0b error=%0b)", name, halted, error);
    npass++;
  endtask

  task automatic expect_error(input int pc);
    if (!error) $fatal(1, "%s: expected error (halted=%0b)", name, halted);
    if (int'(dut.core.pc) != pc) $fatal(1, "%s: error at pc %0d, expected %0d", name, dut.core.pc, pc);
    npass++;
  endtask

  initial begin
    // ---- ロード系
    begin_test("loads");
    prog.push_back(w(OP_LOADI_0, 1));
    prog.push_back(w(OP_LOADI_7, 2));
    prog.push_back(w(OP_LOADI__1, 3));
    prog.push_back(w(OP_LOADI8, 4, 200));
    prog.push_back(w(OP_LOADINEG, 5, 7));
    prog.push_back(w(OP_LOADI16, 6, 16'hFF38));        // -200
    prog.push_back(w(OP_LOADI32, 7, 16'h0001, 16'h3880)); // 80000
    prog.push_back(w(OP_LOADTRUE, 8));
    prog.push_back(w(OP_LOADFALSE, 9));
    prog.push_back(w(OP_LOADI_3, 10));
    prog.push_back(w(OP_LOADNIL, 10));
    prog.push_back(w(OP_MOVE, 11, 7));
    prog.push_back(w(OP_LOADI_1, 12));
    prog.push_back(w(OP_LOADI_2, 13));
    prog.push_back(w(OP_LOADI_4, 14));
    prog.push_back(w(OP_LOADI_5, 15));
    prog.push_back(w(OP_LOADI_6, 0));
    prog.push_back(w(OP_NOP));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(0));
    expect_reg(2, vint(7));
    expect_reg(3, vint(-1));
    expect_reg(4, vint(200));
    expect_reg(5, vint(-7));
    expect_reg(6, vint(-200));
    expect_reg(7, vint(80000));
    expect_reg(8, VTRUE);
    expect_reg(9, VFALSE);
    expect_reg(10, VNIL);
    expect_reg(11, vint(80000));
    expect_reg(12, vint(1));
    expect_reg(13, vint(2));
    expect_reg(14, vint(4));
    expect_reg(15, vint(5));
    expect_reg(0, vint(6));

    // ---- 算術 (32bit で折り返す)
    begin_test("arith");
    prog.push_back(w(OP_LOADI16, 1, 300));
    prog.push_back(w(OP_LOADINEG, 2, 7));
    prog.push_back(w(OP_ADD, 1));                        // R1 = 293
    prog.push_back(w(OP_LOADI16, 3, 300));
    prog.push_back(w(OP_LOADINEG, 4, 7));
    prog.push_back(w(OP_SUB, 3));                        // R3 = 307
    prog.push_back(w(OP_LOADI_5, 5));
    prog.push_back(w(OP_ADDI, 5, 250));                  // 255
    prog.push_back(w(OP_LOADI_5, 6));
    prog.push_back(w(OP_SUBI, 6, 9));                    // -4
    prog.push_back(w(OP_LOADI_0, 7));
    prog.push_back(w(OP_ADDILV, 7, 8, 100));             // 100 (b は使わない)
    prog.push_back(w(OP_LOADI_0, 8));
    prog.push_back(w(OP_SUBILV, 8, 9, 1));               // -1
    prog.push_back(w(OP_LOADI32, 9, 16'h7FFF, 16'hFFFF));
    prog.push_back(w(OP_ADDI, 9, 1));                    // 0x7fffffff + 1 -> -2**31
    prog.push_back(w(OP_RETNIL));
    run();
    expect_halt();
    expect_reg(1, vint(293));
    expect_reg(3, vint(307));
    expect_reg(5, vint(255));
    expect_reg(6, vint(-4));
    expect_reg(7, vint(100));
    expect_reg(8, vint(-1));
    expect_reg(9, vint(32'h8000_0000));

    // ---- 比較
    begin_test("compare");
    prog.push_back(w(OP_LOADINEG, 1, 3)); prog.push_back(w(OP_LOADI_2, 2)); prog.push_back(w(OP_LT, 1)); // -3 < 2
    prog.push_back(w(OP_LOADI_2, 3)); prog.push_back(w(OP_LOADI_2, 4)); prog.push_back(w(OP_LE, 3));     // 2 <= 2
    prog.push_back(w(OP_LOADI_2, 5)); prog.push_back(w(OP_LOADINEG, 6, 3)); prog.push_back(w(OP_GT, 5)); // 2 > -3
    prog.push_back(w(OP_LOADINEG, 7, 3)); prog.push_back(w(OP_LOADI_2, 8)); prog.push_back(w(OP_GE, 7)); // -3 >= 2
    prog.push_back(w(OP_LOADI_2, 9)); prog.push_back(w(OP_LOADI_2, 10)); prog.push_back(w(OP_EQ, 9));   // 2 == 2
    prog.push_back(w(OP_LOADNIL, 11)); prog.push_back(w(OP_LOADNIL, 12)); prog.push_back(w(OP_EQ, 11));  // nil == nil
    prog.push_back(w(OP_LOADNIL, 13)); prog.push_back(w(OP_LOADFALSE, 14)); prog.push_back(w(OP_EQ, 13)); // nil == false
    prog.push_back(w(OP_LOADI_0, 14)); prog.push_back(w(OP_LOADNIL, 15)); prog.push_back(w(OP_EQ, 14));  // 0 == nil
    prog.push_back(w(OP_RETURN, 1));
    run();
    expect_halt();
    expect_reg(1, VTRUE);
    expect_reg(3, VTRUE);
    expect_reg(5, VTRUE);
    expect_reg(7, VFALSE);
    expect_reg(9, VTRUE);
    expect_reg(11, VTRUE);
    expect_reg(13, VFALSE);
    expect_reg(14, VFALSE);

    // ---- 分岐 (nil と false だけが偽、0 は真)
    begin_test("jumps");
    prog.push_back(w(OP_LOADI_0, 1));            // 0
    prog.push_back(w(OP_JMPNOT, 1, 4));          // 1: 0 は真なので落ちる
    prog.push_back(w(OP_LOADI_1, 2));            // 2: 通る
    prog.push_back(w(OP_JMPIF, 1, 5));           // 3: 飛ぶ
    prog.push_back(w(OP_LOADI_7, 2));            // 4: 通らない
    prog.push_back(w(OP_LOADNIL, 3));            // 5
    prog.push_back(w(OP_JMPNIL, 3, 8));          // 6: 飛ぶ
    prog.push_back(w(OP_LOADI_7, 4));            // 7: 通らない
    prog.push_back(w(OP_LOADFALSE, 5));          // 8
    prog.push_back(w(OP_JMPNIL, 5, 11));         // 9: false は nil ではないので落ちる
    prog.push_back(w(OP_JMP, 0, 12));            // 10: 飛ぶ
    prog.push_back(w(OP_LOADI_7, 6));            // 11: 通らない
    prog.push_back(w(OP_JMPNOT, 5, 14));         // 12: false なので飛ぶ
    prog.push_back(w(OP_LOADI_7, 7));            // 13: 通らない
    prog.push_back(w(OP_STOP));                  // 14
    run();
    expect_halt();
    expect_reg(2, vint(1));
    expect_reg(4, VNIL);
    expect_reg(6, VNIL);
    expect_reg(7, VNIL);

    // ---- I/O
    begin_test("io");
    in_val[PORT_BUTTON] = 32'd1;
    prog.push_back(w(OP_GETGV, 1, PORT_LED));    // 書く前の出力ポートは nil
    prog.push_back(w(OP_LOADI_3, 2));
    prog.push_back(w(OP_SETGV, 2, PORT_LED));
    prog.push_back(w(OP_GETGV, 3, PORT_LED));    // 書いた値が読める
    prog.push_back(w(OP_GETGV, 4, PORT_BUTTON)); // 入力は Integer
    prog.push_back(w(OP_LOADTRUE, 5));
    prog.push_back(w(OP_SETGV, 5, PORT_LED2));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, VNIL);
    expect_reg(3, vint(3));
    expect_reg(4, vint(1));
    expect_out(PORT_LED, vint(3));
    expect_out(PORT_LED2, VTRUE);
    in_val = '0;

    // ---- エラー停止
    begin_test("add nil");
    prog.push_back(w(OP_LOADI_1, 1)); prog.push_back(w(OP_LOADNIL, 2)); prog.push_back(w(OP_ADD, 1));
    prog.push_back(w(OP_STOP));
    run();
    expect_error(2);
    expect_reg(1, vint(1));                      // エラーの命令は書かない

    begin_test("lt true");
    prog.push_back(w(OP_LOADTRUE, 1)); prog.push_back(w(OP_LOADI_1, 2)); prog.push_back(w(OP_LT, 1));
    run();
    expect_error(2);

    begin_test("addilv nil");
    prog.push_back(w(OP_ADDILV, 1, 2, 1));
    run();
    expect_error(0);

    begin_test("unsupported op");
    prog.push_back(w(OP_NOP));
    prog.push_back(w(8'd50));                    // SEND0
    run();
    expect_error(1);

    begin_test("run off the end");
    prog.push_back(w(OP_NOP));
    run();
    expect_error(1);

    begin_test("register out of range");
    prog.push_back(w(OP_LOADI_1, 8'(NREGS)));
    run();
    expect_error(0);

    begin_test("setgv bad port");
    prog.push_back(w(OP_SETGV, 0, 16'(NPORTS)));
    run();
    expect_error(0);

    // ---- メソッド呼び出し (レジスタ窓): add(3, 4)
    begin_test("call and return");
    prog.push_back(w(OP_LOADI_3, 2));                        // 0
    prog.push_back(w(OP_LOADI_4, 3));                        // 1
    prog.push_back(w(OP_SSEND, 1, 4, (6 << 8) | 2));         // 2: bp 0 -> 1
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_ENTER, 2));                          // 4: add
    prog.push_back(w(OP_MOVE, 4, 1));
    prog.push_back(w(OP_MOVE, 5, 2));
    prog.push_back(w(OP_ADD, 4));
    prog.push_back(w(OP_RETURN, 4));
    run();
    expect_halt();
    expect_reg(1, vint(7));
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after return", name, dut.core.sp, dut.core.bp);

    begin_test("callee registers are cleared, RETNIL returns nil");
    prog.push_back(w(OP_LOADI_5, 3));                        // 0: 呼び出し先の R2 と同じ場所
    prog.push_back(w(OP_LOADI_1, 2));                        // 1: 引数
    prog.push_back(w(OP_SSEND, 1, 5, (4 << 8) | 1));         // 2
    prog.push_back(w(OP_SSEND0, 4, 7, (3 << 8) | 0));        // 3: 引数なし
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_ENTER, 1));                          // 5: 引数の後ろ (R2) は nil
    prog.push_back(w(OP_RETURN, 2));                         // 6
    prog.push_back(w(OP_ENTER, 0));                          // 7
    prog.push_back(w(OP_RETNIL));                            // 8
    prog.push_back(w(OP_LOADI_7, 4));                        // 9: (通らない)
    run();
    expect_halt();
    expect_reg(1, VNIL);
    expect_reg(4, VNIL);

    begin_test("wrong number of arguments");
    prog.push_back(w(OP_SSEND, 1, 2, (4 << 8) | 1));         // 0
    prog.push_back(w(OP_STOP));                              // 1
    prog.push_back(w(OP_ENTER, 2));                          // 2
    run();
    expect_error(2);

    begin_test("stack overflow");
    prog.push_back(w(OP_SSEND0, 0, 0, (1 << 8) | 0));        // 0: 自分を呼び続ける (bp は進まない)
    run();
    expect_error(0);
    if (dut.core.sp != STACK_DEPTH) $fatal(1, "%s: sp=%0d", name, dut.core.sp);

    begin_test("register window overflow");
    prog.push_back(w(OP_SSEND0, 8, 0, (9 << 8) | 0));        // 0: bp を 8 ずつ進め、16 本を超える
    run();
    expect_error(0);

    // ---- 定数
    begin_test("constants");
    prog.push_back(w(OP_LOADI_6, 1));
    prog.push_back(w(OP_SETCONST, 1, 3));
    prog.push_back(w(OP_GETCONST, 2, 3));
    prog.push_back(w(OP_TDEF, 3));                           // R3 = nil
    prog.push_back(w(OP_GETCONST, 4, 5));                    // 未定義
    run();
    expect_error(4);
    expect_reg(2, vint(6));
    expect_reg(3, VNIL);

    // ---- 掛け算・割り算 (floor 側)
    begin_test("mul div");
    prog.push_back(w(OP_LOADI_7, 1)); prog.push_back(w(OP_LOADINEG, 2, 6)); prog.push_back(w(OP_MUL, 1));      // -42
    prog.push_back(w(OP_LOADINEG, 3, 7)); prog.push_back(w(OP_LOADI_2, 4)); prog.push_back(w(OP_DIV, 3));      // -4
    prog.push_back(w(OP_LOADI_7, 5)); prog.push_back(w(OP_LOADINEG, 6, 2)); prog.push_back(w(OP_DIV, 5));      // -4
    prog.push_back(w(OP_LOADI32, 7, 16'h8000, 16'h0000)); prog.push_back(w(OP_LOADI__1, 8)); prog.push_back(w(OP_DIV, 7)); // INT_MIN
    prog.push_back(w(OP_LOADI_1, 9)); prog.push_back(w(OP_LOADI_0, 10)); prog.push_back(w(OP_DIV, 9));       // 0 で割る
    run();
    expect_error(14);
    expect_reg(1, vint(-42));
    expect_reg(3, vint(-4));
    expect_reg(5, vint(-4));
    expect_reg(7, vint(32'h8000_0000));

    // ---- 組み込みメソッド (SEND の b = 番号、c = 引数の数)
    begin_test("builtins");
    prog.push_back(w(OP_LOADINEG, 1, 7)); prog.push_back(w(OP_LOADI_3, 2)); prog.push_back(w(OP_SEND, 1, BI_MOD, 1));  // -7 % 3 = 2
    prog.push_back(w(OP_LOADI_1, 3)); prog.push_back(w(OP_LOADI_4, 4)); prog.push_back(w(OP_SEND, 3, BI_SHL, 1));      // 16
    prog.push_back(w(OP_LOADINEG, 5, 16)); prog.push_back(w(OP_LOADI_2, 6)); prog.push_back(w(OP_SEND, 5, BI_SHR, 1)); // -4
    prog.push_back(w(OP_LOADI_5, 7)); prog.push_back(w(OP_LOADI__1, 8)); prog.push_back(w(OP_SEND, 7, BI_SHL, 1));     // 5 << -1 = 2
    prog.push_back(w(OP_LOADI_6, 9)); prog.push_back(w(OP_LOADI_3, 10)); prog.push_back(w(OP_SEND, 9, BI_XOR, 1));     // 5
    prog.push_back(w(OP_LOADI8, 11, 12)); prog.push_back(w(OP_SEND0, 11, BI_INV, 0));                                 // -13
    prog.push_back(w(OP_LOADINEG, 12, 9)); prog.push_back(w(OP_SEND0, 12, BI_ABS, 0));                                // 9
    prog.push_back(w(OP_LOADNIL, 13)); prog.push_back(w(OP_SEND0, 13, BI_NOT, 0));                                    // !nil = true
    prog.push_back(w(OP_LOADNIL, 14)); prog.push_back(w(OP_LOADNIL, 15)); prog.push_back(w(OP_SEND, 14, BI_NEQ, 1));  // false
    prog.push_back(w(OP_LOADI_6, 0)); prog.push_back(w(OP_SEND0, 0, BI_ODD, 0));                                      // false
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(2));
    expect_reg(3, vint(16));
    expect_reg(5, vint(-4));
    expect_reg(7, vint(2));
    expect_reg(9, vint(5));
    expect_reg(11, vint(-13));
    expect_reg(12, vint(9));
    expect_reg(13, VTRUE);
    expect_reg(14, VFALSE);
    expect_reg(0, VFALSE);

    begin_test("builtin errors");
    prog.push_back(w(OP_LOADI_1, 1)); prog.push_back(w(OP_LOADI_0, 2)); prog.push_back(w(OP_SEND, 1, BI_MOD, 1));    // 0 で割った余り
    run();
    expect_error(2);
    begin_test("builtin on nil");
    prog.push_back(w(OP_SEND0, 1, BI_NEG, 0));
    run();
    expect_error(0);
    begin_test("builtin with wrong argc");
    prog.push_back(w(OP_SEND0, 1, BI_MOD, 0));
    run();
    expect_error(0);

    // ---- Proc (BLOCK / BLKCALL): 外側の変数と break
    begin_test("proc, upvar and break");
    prog.push_back(w(OP_LOADI_5, 1));                        // 0: 外側の R1 = 5
    prog.push_back(w(OP_BLOCK, 3, 6, (4 << 8) | 0));         // 1: R3 = Proc (先頭 pc 6、引数 0、nregs 4)
    prog.push_back(w(OP_BLKCALL, 3, 0));                     // 2: ブロックのフレームは bp + 3
    prog.push_back(w(OP_LOADI_7, 2));                        // 3: (break で飛ばされる)
    prog.push_back(w(OP_STOP));                              // 4: break の出口
    prog.push_back(w(OP_STOP));                              // 5
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 6: R1 = 作ったフレームの R1
    prog.push_back(w(OP_ADDI, 1, 1));                        // 7
    prog.push_back(w(OP_SETUPVAR, 1, 1, 1));                 // 8: 作ったフレームの R1 = 6
    prog.push_back(w(OP_BREAK, 1, 4, 0));                    // 9: 値 6 を持って出口 (pc 4) へ
    run();
    expect_halt();
    expect_reg(1, vint(6));
    expect_reg(2, VNIL);                                     // pc 3 は通らない
    expect_reg(3, vint(6));                                  // break の値はブロックのフレームの R0 (= 外側の R3)
    expect_reg(4, vint(6));                                  // ブロックの R1
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after break", name, dut.core.sp, dut.core.bp);

    begin_test("yield through a method and dynamic break");
    prog.push_back(w(OP_BLOCK, 2, 7, (3 << 8) | 1));         // 0: R2 = Proc (先頭 pc 7、引数 1)
    prog.push_back(w(OP_SSEND, 1, 4, (5 << 8) | 8'h80 | 0)); // 1: m(&blk)。ブロックの枠 (R1 + 1) を残す
    prog.push_back(w(OP_STOP));                              // 2: break の戻り先
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_BLKPUSH, 2, 1, 0));                  // 4: m: R2 = 自分のブロック (枠 1)
    prog.push_back(w(OP_LOADI_4, 3));                        // 5: yield 4
    prog.push_back(w(OP_BLKCALL, 2, 1));                     // 6
    prog.push_back(w(OP_ADDI, 1, 2));                        // 7: ブロック: R1 (= 4) + 2
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 8: Proc を作ったフレームまで畳む
    run();
    expect_halt();
    expect_reg(1, vint(6));                                  // m(...) の結果が break の値
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after break", name, dut.core.sp, dut.core.bp);

    // ---- 配列 (ヒープ)
    begin_test("arrays");
    prog.push_back(w(OP_LOADI_3, 1));                        // 0
    prog.push_back(w(OP_LOADI_1, 2));                        // 1
    prog.push_back(w(OP_LOADI_4, 3));                        // 2
    prog.push_back(w(OP_ARRAY2, 4, 1, 3));                   // 3: R4 = [3, 1, 4]
    prog.push_back(w(OP_MOVE, 5, 4));                        // 4
    prog.push_back(w(OP_LOADI__1, 6));                       // 5
    prog.push_back(w(OP_GETIDX, 5));                         // 6: R5 = a[-1] = 4
    prog.push_back(w(OP_GETIDX0, 6, 4));                     // 7: R6 = a[0] = 3
    prog.push_back(w(OP_MOVE, 7, 4));                        // 8
    prog.push_back(w(OP_LOADI_5, 8));                        // 9
    prog.push_back(w(OP_LOADI_7, 9));                        // 10
    prog.push_back(w(OP_SETIDX, 7));                         // 11: a[5] = 7 (容量を超えて伸ばす)
    prog.push_back(w(OP_MOVE, 10, 4));                       // 12
    prog.push_back(w(OP_SEND0, 10, BI_SIZE));                // 13: R10 = 6
    prog.push_back(w(OP_MOVE, 11, 4));                       // 14
    prog.push_back(w(OP_SEND0, 11, BI_POP));                 // 15: R11 = 7
    prog.push_back(w(OP_MOVE, 12, 4));                       // 16
    prog.push_back(w(OP_SEND0, 12, BI_LAST));                // 17: R12 = nil (a[4])
    prog.push_back(w(OP_MOVE, 13, 4));                       // 18
    prog.push_back(w(OP_LOADI_1, 14));                       // 19
    prog.push_back(w(OP_SEND, 13, BI_PUSH, 1));              // 20: a.push(1) は a を返す
    prog.push_back(w(OP_MOVE, 14, 4));                       // 21
    prog.push_back(w(OP_SEND0, 14, BI_LENGTH));              // 22: R14 = 6
    prog.push_back(w(OP_MOVE, 8, 4));                        // 23
    prog.push_back(w(OP_LOADI_4, 9));                        // 24
    prog.push_back(w(OP_SEND, 8, BI_INCL, 1));               // 25: R8 = a.include?(4) = true
    prog.push_back(w(OP_MOVE, 1, 4));                        // 26
    prog.push_back(w(OP_SEND0, 1, BI_FIRST));                // 27: R1 = 3
    prog.push_back(w(OP_ARRAY, 2, 0));                       // 28: R2 = []
    prog.push_back(w(OP_SEND0, 2, BI_EMPTY));                // 29: R2 = true
    prog.push_back(w(OP_LOADI_5, 3));                        // 30
    prog.push_back(w(OP_ARRAY, 3, 1));                       // 31: R3 = [5]
    prog.push_back(w(OP_GETIDX0, 3, 3));                     // 32: R3 = 5
    prog.push_back(w(OP_STOP));                              // 33
    run();
    expect_halt();
    expect_reg(5, vint(4));
    expect_reg(6, vint(3));
    expect_reg(10, vint(6));
    expect_reg(11, vint(7));
    expect_reg(12, VNIL);
    expect_reg(13, dut.core.regs[4]);                        // push は同じ配列 (同一の参照)
    if (dut.core.regs[4][VAL_BITS-1 -: TAG_BITS] != TAG_OBJ) $fatal(1, "%s: R4 is not an array", name);
    expect_reg(14, vint(6));
    expect_reg(8, VTRUE);
    expect_reg(1, vint(3));
    expect_reg(2, VTRUE);
    expect_reg(3, vint(5));

    begin_test("array == array is an error");
    prog.push_back(w(OP_ARRAY, 1, 0));
    prog.push_back(w(OP_MOVE, 2, 1));
    prog.push_back(w(OP_EQ, 1));                             // 配列の比較は持たない (参照の == は Ruby と違う)
    run();
    expect_error(2);

    begin_test("array to a pin is an error");
    prog.push_back(w(OP_ARRAY, 1, 0));
    prog.push_back(w(OP_SETGV, 1, PORT_LED));
    run();
    expect_error(1);

    begin_test("index a non-array");
    prog.push_back(w(OP_LOADI_1, 1));
    prog.push_back(w(OP_LOADI_0, 2));
    prog.push_back(w(OP_GETIDX, 1));
    run();
    expect_error(2);

    begin_test("gc keeps live arrays");
    prog.push_back(w(OP_LOADI_5, 1));                        // 0
    prog.push_back(w(OP_ARRAY2, 2, 1, 1));                   // 1: R2 = [5] (生きている)
    prog.push_back(w(OP_LOADI16, 3, 600));                   // 2: 600 回
    prog.push_back(w(OP_ARRAY2, 4, 1, 1));                   // 3: ゴミを作る (半空間を何度も溢れさせる)
    prog.push_back(w(OP_SUBI, 3, 1));                        // 4
    prog.push_back(w(OP_MOVE, 5, 3));                        // 5
    prog.push_back(w(OP_LOADI_0, 6));                        // 6
    prog.push_back(w(OP_GT, 5));                             // 7
    prog.push_back(w(OP_JMPIF, 5, 3));                       // 8
    prog.push_back(w(OP_GETIDX0, 7, 2));                     // 9: R7 = R2[0]
    prog.push_back(w(OP_STOP));                              // 10
    run();
    expect_halt();
    expect_reg(7, vint(5));
    if (gcs < 2) $fatal(1, "%s: only %0d gc(s)", name, gcs);

    // ---- ブロックの中の return は、ブロックを作ったメソッドから戻る
    begin_test("return from a block");
    prog.push_back(w(OP_SSEND0, 1, 3, 5 << 8));              // 0: R1 = m
    prog.push_back(w(OP_STOP));                              // 1
    prog.push_back(w(OP_STOP));                              // 2
    prog.push_back(w(OP_LOADI_1, 1));                        // 3: m
    prog.push_back(w(OP_BLOCK, 2, 8, 3 << 8));               // 4
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 5
    prog.push_back(w(OP_LOADI_7, 1));                        // 6: (通らない)
    prog.push_back(w(OP_RETURN, 1));                         // 7
    prog.push_back(w(OP_LOADI8, 1, 9));                      // 8: ブロック: return 9
    prog.push_back(w(OP_RETURN_BLK, 1, 0, 1));               // 9: 1段外のメソッドから戻る
    run();
    expect_halt();
    expect_reg(1, vint(9));
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after return", name, dut.core.sp, dut.core.bp);

    // ---- 時間待ち: sleep_ms n は ms_tick を n 回数えて n を返す
    begin_test("sleep_ms 0");
    prog.push_back(w(OP_LOADI_0, 2));                        // self (R1) は nil、引数は R2
    prog.push_back(w(OP_SEND, 1, BI_SLEEPMS, 1));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(0));
    base_cycles = cycles;

    begin_test("sleep_ms 100");
    prog.push_back(w(OP_LOADI8, 2, 100));
    prog.push_back(w(OP_SEND, 1, BI_SLEEPMS, 1));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(100));
    if (cycles - base_cycles < 100 || cycles - base_cycles > 110)
      $fatal(1, "%s: waited %0d cycles more than sleep_ms 0 (ms_tick every cycle)", name, cycles - base_cycles);

    begin_test("sleep with a negative time");
    prog.push_back(w(OP_LOADI__1, 2));
    prog.push_back(w(OP_SEND, 1, BI_SLEEP, 1));
    run();
    expect_error(1);

    // ---- env: メソッドから戻った後も、その変数を Proc から読み書きできる
    begin_test("closure outlives its method");
    prog.push_back(w(OP_SSEND0, 1, 7, 3 << 8));              // 0: R1 = m (Proc が返る)
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: R1 = 6 (env の R1 を 5 から 6 に)
    prog.push_back(w(OP_MOVE, 6, 1));                        // 2: R6 = 6 (2本目の呼び出しのフレームより上)
    prog.push_back(w(OP_SSEND0, 1, 7, 3 << 8));              // 3: 別の env
    prog.push_back(w(OP_MOVE, 2, 1));                        // 4: R2 = 2本目の Proc
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 5: R2 = 6 (1本目とは別の env)
    prog.push_back(w(OP_STOP));                              // 6
    prog.push_back(w(OP_LOADI_5, 1));                        // 7: m: R1 = 5
    prog.push_back(w(OP_BLOCK, 2, 10, 3 << 8));              // 8: R2 = Proc (env を作る)
    prog.push_back(w(OP_RETURN, 2));                         // 9: 戻る時に env へ R0..R2 を写す
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 10: ブロック: R1 = env の R1
    prog.push_back(w(OP_ADDI, 1, 1));                        // 11
    prog.push_back(w(OP_SETUPVAR, 1, 1, 1));                 // 12: env の R1 = R1 (ヒープへ)
    prog.push_back(w(OP_RETURN, 1));                         // 13
    run();
    expect_halt();
    expect_reg(6, vint(6));
    expect_reg(2, vint(6));                                  // 2本目は別の env (5 から数え直す)

    begin_test("break to a method that has returned");
    prog.push_back(w(OP_SSEND0, 1, 3, 3 << 8));              // 0
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: break の行き先のフレームはもう無い
    prog.push_back(w(OP_STOP));                              // 2
    prog.push_back(w(OP_BLOCK, 2, 5, 3 << 8));               // 3: m
    prog.push_back(w(OP_RETURN, 2));                         // 4
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 5
    run();
    expect_error(5);

    // ---- lambda: 引数の数を調べ、break / return は lambda から戻る
    begin_test("lambda checks the number of arguments");
    prog.push_back(w(OP_BLOCK, 1, 2, (3 << 8) | 8'h80 | 1)); // 0: lambda { |x| }
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: 引数 0 個
    prog.push_back(w(OP_RETNIL));                            // 2
    run();
    expect_error(1);

    begin_test("break in a lambda");
    prog.push_back(w(OP_BLOCK, 1, 5, (3 << 8) | 8'h80 | 1)); // 0: lambda { |x| break x + 1 }
    prog.push_back(w(OP_LOADI_4, 2));                        // 1
    prog.push_back(w(OP_BLKCALL, 1, 1));                     // 2: R1 = 5
    prog.push_back(w(OP_LOADI_7, 3));                        // 3: 通る (lambda から戻っただけ)
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_ADDI, 1, 1));                        // 5
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 6
    run();
    expect_halt();
    expect_reg(1, vint(5));
    expect_reg(3, vint(7));

    begin_test("return in a proc inside a lambda");
    prog.push_back(w(OP_BLOCK, 1, 4, (4 << 8) | 8'h80));     // 0: l = lambda { proc { return 9 }.call; 1 }
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: R1 = 9
    prog.push_back(w(OP_LOADI_7, 2));                        // 2
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_BLOCK, 2, 8, 3 << 8));               // 4: lambda の中: proc
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 5
    prog.push_back(w(OP_LOADI_1, 1));                        // 6: (通らない)
    prog.push_back(w(OP_RETURN, 1));                         // 7
    prog.push_back(w(OP_LOADI8, 1, 9));                      // 8: proc の中
    prog.push_back(w(OP_RETURN_BLK, 1, 0, 2));               // 9: 深さ 1 の lambda から戻る
    run();
    expect_halt();
    expect_reg(1, vint(9));
    expect_reg(2, vint(7));
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after return", name, dut.core.sp, dut.core.bp);

    // ---- シンボル: 番号の即値。== は番号で比べる
    begin_test("symbols");
    prog.push_back(w(OP_LOADSYM, 1, 3));                     // 0: R1 = :s3
    prog.push_back(w(OP_LOADSYM, 2, 3));                     // 1
    prog.push_back(w(OP_EQ, 1));                             // 2: R1 = true
    prog.push_back(w(OP_LOADSYM, 3, 3));                     // 3
    prog.push_back(w(OP_LOADSYM, 4, 4));                     // 4
    prog.push_back(w(OP_EQ, 3));                             // 5: R3 = false
    prog.push_back(w(OP_LOADSYM, 5, 7));                     // 6
    prog.push_back(w(OP_STOP));                              // 7
    run();
    expect_halt();
    expect_reg(1, VTRUE);
    expect_reg(3, VFALSE);
    expect_reg(5, {TAG_SYM, 32'd7});

    // ---- 多重代入 (AREF)
    begin_test("aref");
    prog.push_back(w(OP_LOADI_3, 1));                        // 0
    prog.push_back(w(OP_LOADI_4, 2));                        // 1
    prog.push_back(w(OP_ARRAY2, 3, 1, 2));                   // 2: R3 = [3, 4]
    prog.push_back(w(OP_AREF, 4, 3, 1));                     // 3: R4 = 4
    prog.push_back(w(OP_AREF, 5, 3, 2));                     // 4: R5 = nil (範囲外)
    prog.push_back(w(OP_AREF, 6, 1, 0));                     // 5: R6 = 3 (配列でなければ自身)
    prog.push_back(w(OP_AREF, 7, 1, 1));                     // 6: R7 = nil
    prog.push_back(w(OP_STOP));                              // 7
    run();
    expect_halt();
    expect_reg(4, vint(4));
    expect_reg(5, VNIL);
    expect_reg(6, vint(3));
    expect_reg(7, VNIL);

    begin_test("upvar below the register file");
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 一番外では Proc が無い
    run();
    expect_error(0);

    begin_test("break outside a block");
    prog.push_back(w(OP_BREAK, 1, 0));
    run();
    expect_error(0);

    $display("%0d cases ok", npass);
    $display("PASS mrb_core_tb");
    $finish;
  end
endmodule
