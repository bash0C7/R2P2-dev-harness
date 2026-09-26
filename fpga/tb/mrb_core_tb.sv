// mrb_core の命令ごとの自己チェック型テストベンチ。
// 小さなプログラムを ROM に直接書き、止まるまで回して、レジスタ・I/O・停止状態を見る。
// 対応命令 (tools/fpga/isa.rb の SUPPORTED) のすべてを少なくとも1回ずつ通す。
`timescale 1ns / 1ps
// テストベンチでは定数の幅合わせは邪魔なだけなので、幅の lint はこの file だけ切る (RTL は -Wall のまま)
/* verilator lint_off WIDTH */
module mrb_core_tb;
  import mrb_pkg::*;

  localparam int PC_BITS = 8;
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

  // メソッド表: ROM の最後の TB_SIZE 語。ケースは pc 0 に w_table() を置き、method_entry で中身を足す
  localparam int TB_LOG  = 5;
  localparam int TB_SIZE = 2**TB_LOG;
  localparam int TB_BASE = 2**PC_BITS - TB_SIZE;
  logic [47:0] table_w [TB_SIZE];

  function automatic logic [47:0] w_table();
    return w(OP_TABLE, TB_LOG, TB_BASE);
  endfunction

  // 例外の表の1語 (isa.rb の CATCH_*): {種類 << 15 | 飛び先, begin, end}
  function automatic logic [47:0] w_catch(input logic ens, input logic [14:0] beg, input logic [15:0] en, input logic [14:0] tgt);
    return {ens, tgt, 16'(beg), en};
  endfunction

  function automatic logic [15:0] tgt_prim(input logic [13:0] p);
    return {TGT_PRIM, p};
  endfunction

  // (クラス, シンボル) -> 飛び先 を変換器と同じハッシュ (クラス * 5 + シンボル) と開番地法で入れる
  task automatic method_entry(input logic [15:0] cls, input logic [15:0] sym, input logic [15:0] tgt);
    int h;
    h = (int'(cls) * 5 + int'(sym)) & (TB_SIZE - 1);
    while (table_w[h] != '1) h = (h + 1) & (TB_SIZE - 1);
    table_w[h] = {cls, sym, tgt};
  endtask

  // +dumprom=<dir>: 各ケースの ROM を <dir>/<番号>.hex (名前は <dir>/cases.txt) に書く。rake fpga:tb:ref が
  // 参照インタプリタで走らせて終わりの状態を出す (期待値は先にそれで確かめてから書く)
  int    ncase = 0;
  string dumpdir;

  task automatic begin_test(input string n);
    name = n;
    prog.delete();
    if ($test$plusargs("verbose")) begin $display("case: %s at %0t", n, $time); $fflush(); end
    for (int i = 0; i < TB_SIZE; i++) table_w[i] = '1;
  endtask

  task automatic run();
    #1; // mrb_soc の initial (ROM を全 bit 1 で埋める) より後に書く
    for (int i = 0; i < 2**PC_BITS; i++) dut.rom[i] = (i < prog.size()) ? prog[i] : '1;
    for (int i = 0; i < TB_SIZE; i++) dut.rom[TB_BASE + i] = table_w[i];
    if ($value$plusargs("dumprom=%s", dumpdir)) begin
      int fd;
      $writememh($sformatf("%s/%0d.hex", dumpdir, ncase), dut.rom);
      fd = $fopen($sformatf("%s/cases.txt", dumpdir), ncase == 0 ? "w" : "a");
      $fdisplay(fd, "%0d %s", ncase, name);
      $fclose(fd);
      ncase++;
    end
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
    if (!halted || error) $fatal(1, "%s: expected halt (halted=%0b error=%0b pc=%0d)", name, halted, error, dut.core.pc);
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
    expect_reg(13, VFALSE);

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

    // ---- メソッド呼び出し (レジスタ窓、メソッド表): add(3, 4)。一番外の self は nil なので NilClass に置く
    begin_test("call and return");
    method_entry(CLS_NIL, 20, 16'd5);                        // (NilClass, :add) -> pc 5
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_3, 2));                        // 1
    prog.push_back(w(OP_LOADI_4, 3));                        // 2
    prog.push_back(w(OP_SSEND, 1, 20, 2));                   // 3: bp 0 -> 1
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_ENTER, 2, 6));                       // 5: add (引数 2、nregs 6)
    prog.push_back(w(OP_MOVE, 4, 1));                        // 6
    prog.push_back(w(OP_MOVE, 5, 2));                        // 7
    prog.push_back(w(OP_ADD, 4));                            // 8
    prog.push_back(w(OP_RETURN, 4));                         // 9
    run();
    expect_halt();
    expect_reg(1, vint(7));
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after return", name, dut.core.sp, dut.core.bp);

    begin_test("callee registers are cleared, RETNIL returns nil");
    method_entry(CLS_NIL, 20, 16'd8);
    method_entry(CLS_NIL, 21, 16'd10);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_5, 3));                        // 1: 呼び出し先の R2 (ブロックの枠) の場所
    prog.push_back(w(OP_LOADI_7, 4));                        // 2: 呼び出し先の R3 の場所
    prog.push_back(w(OP_LOADI_1, 2));                        // 3: 引数
    prog.push_back(w(OP_SSEND, 1, 20, 1));                   // 4: R1 = m(1)
    prog.push_back(w(OP_LOADI_7, 5));                        // 5
    prog.push_back(w(OP_SSEND0, 5, 21));                     // 6: R5 = n
    prog.push_back(w(OP_STOP));                              // 7
    prog.push_back(w(OP_ENTER, 1, 4));                       // 8: m: 枠 (R2) は呼び出しが、R3 は ENTER が nil にする
    prog.push_back(w(OP_RETURN, 2));                         // 9
    prog.push_back(w(OP_ENTER, 0, 3));                       // 10: n
    prog.push_back(w(OP_RETNIL));                            // 11
    run();
    expect_halt();
    expect_reg(1, VNIL);
    expect_reg(3, VNIL);
    expect_reg(4, VNIL);
    expect_reg(5, VNIL);

    begin_test("wrong number of arguments");
    method_entry(CLS_NIL, 20, 16'd3);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND, 1, 20, 1));                   // 1
    prog.push_back(w(OP_STOP));                              // 2
    prog.push_back(w(OP_ENTER, 2, 4));                       // 3
    run();
    expect_error(3);

    begin_test("stack overflow");
    method_entry(CLS_NIL, 20, 16'd1);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 0, 20));                     // 1: 自分を呼び続ける (bp は進まない)
    run();
    expect_error(1);
    if (dut.core.sp != STACK_DEPTH) $fatal(1, "%s: sp=%0d", name, dut.core.sp);

    begin_test("register window overflow");
    method_entry(CLS_NIL, 20, 16'd1);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 8, 20));                     // 1: bp を 8 ずつ進め、16 本を超える
    run();
    expect_error(1);

    begin_test("method missing");
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);           // nil -> Object にも無い
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 1
    run();
    expect_error(1);

    begin_test("no method table");
    prog.push_back(w(OP_SSEND0, 1, 20));                     // TABLE を実行していなければどれも見つからない
    run();
    expect_error(0);

    begin_test("superclass chain and class methods");
    method_entry(16'd33, SUPER_SYM, 16'd32);                 // class B < A
    method_entry(CLS_META | 16'd33, SUPER_SYM, CLS_META | 16'd32);
    method_entry(CLS_META | 16'd32, 21, 16'd7);              // def A.make
    method_entry(16'd32, 22, 16'd9);                         // def A#get
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_CLASS, 1, 33));                      // 1: R1 = B
    prog.push_back(w(OP_SEND0, 1, 21));                      // 2: B.make (A のクラスメソッド)
    prog.push_back(w(OP_MOVE, 4, 1));                        // 3: R4 = 7
    prog.push_back(w(OP_CLASS, 1, 32));                      // 4
    prog.push_back(w(OP_SEND0, 1, 22));                      // 5: A.get (インスタンスメソッドはクラスには無い)
    prog.push_back(w(OP_STOP));                              // 6
    prog.push_back(w(OP_LOADI_7, 2));                        // 7: A.make
    prog.push_back(w(OP_RETURN, 2));                         // 8
    prog.push_back(w(OP_RETNIL));                            // 9
    run();
    expect_error(5);
    expect_reg(4, vint(7));

    begin_test("operators send a method to non-integers");
    method_entry(CLS_ARRAY, SYM_ADD, 16'd5);                 // Array#+ (この表では自分で定義)
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_ARRAY, 1, 0));                       // 1: R1 = []
    prog.push_back(w(OP_LOADI_1, 2));                        // 2
    prog.push_back(w(OP_ADD, 1));                            // 3: [] + 1 は + を送る
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_MOVE, 3, 1));                        // 5: Array#+: 引数 + 6 を返す
    prog.push_back(w(OP_ADDI, 3, 6));                        // 6
    prog.push_back(w(OP_RETURN, 3));                         // 7
    run();
    expect_halt();
    expect_reg(1, vint(7));

    // ---- 定数
    begin_test("constants");
    prog.push_back(w(OP_LOADI_6, 1));
    prog.push_back(w(OP_SETCONST, 1, 3));
    prog.push_back(w(OP_GETCONST, 2, 3));
    prog.push_back(w(OP_TDEF, 3, 5));                        // R3 = :s5 (メソッドの名前)
    prog.push_back(w(OP_GETCONST, 4, 5));                    // 未定義
    run();
    expect_error(4);
    expect_reg(2, vint(6));
    expect_reg(3, {TAG_SYM, 32'd5});

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

    // ---- primitive (メソッド表の飛び先が回路のメソッド)
    begin_test("builtins");
    method_entry(CLS_INT, 30, tgt_prim(PR_MOD));
    method_entry(CLS_INT, 31, tgt_prim(PR_SHL));
    method_entry(CLS_INT, 32, tgt_prim(PR_SHR));
    method_entry(CLS_INT, 33, tgt_prim(PR_XOR));
    method_entry(CLS_INT, 34, tgt_prim(PR_INV));
    method_entry(CLS_INT, 35, tgt_prim(PR_ABS));
    method_entry(CLS_INT, 37, tgt_prim(PR_ODD));
    method_entry(CLS_OBJECT, 36, tgt_prim(PR_NOT));
    method_entry(CLS_OBJECT, 38, tgt_prim(PR_OEQ));
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);
    method_entry(CLS_INT, SUPER_SYM, CLS_OBJECT);
    prog.push_back(w_table());                                                                                        // 0
    prog.push_back(w(OP_LOADINEG, 1, 7)); prog.push_back(w(OP_LOADI_3, 2)); prog.push_back(w(OP_SEND, 1, 30, 1));    // -7 % 3 = 2
    prog.push_back(w(OP_LOADI_1, 3)); prog.push_back(w(OP_LOADI_4, 4)); prog.push_back(w(OP_SEND, 3, 31, 1));        // 16
    prog.push_back(w(OP_LOADINEG, 5, 16)); prog.push_back(w(OP_LOADI_2, 6)); prog.push_back(w(OP_SEND, 5, 32, 1));   // -4
    prog.push_back(w(OP_LOADI_5, 7)); prog.push_back(w(OP_LOADI__1, 8)); prog.push_back(w(OP_SEND, 7, 31, 1));       // 5 << -1 = 2
    prog.push_back(w(OP_LOADI_6, 9)); prog.push_back(w(OP_LOADI_3, 10)); prog.push_back(w(OP_SEND, 9, 33, 1));       // 5
    prog.push_back(w(OP_LOADI8, 11, 12)); prog.push_back(w(OP_SEND0, 11, 34));                                       // -13
    prog.push_back(w(OP_LOADINEG, 12, 9)); prog.push_back(w(OP_SEND0, 12, 35));                                      // 9
    prog.push_back(w(OP_LOADNIL, 13)); prog.push_back(w(OP_LOADNIL, 14)); prog.push_back(w(OP_SEND, 13, 38, 1));     // nil == nil (Object)
    prog.push_back(w(OP_LOADNIL, 14)); prog.push_back(w(OP_SEND0, 14, 36));                                          // !nil = true
    prog.push_back(w(OP_LOADI_6, 0)); prog.push_back(w(OP_SEND0, 0, 37));                                            // 6.odd? = false
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
    expect_reg(14, VTRUE);
    expect_reg(0, VFALSE);

    begin_test("builtin errors");
    method_entry(CLS_INT, 30, tgt_prim(PR_MOD));
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI_1, 1)); prog.push_back(w(OP_LOADI_0, 2)); prog.push_back(w(OP_SEND, 1, 30, 1));        // 0 で割った余り
    run();
    expect_error(3);
    begin_test("builtin with wrong argc");
    method_entry(CLS_INT, 30, tgt_prim(PR_MOD));
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI_1, 1));
    prog.push_back(w(OP_SEND0, 1, 30));
    run();
    expect_error(2);
    begin_test("builtin on the wrong receiver");
    method_entry(CLS_NIL, 30, tgt_prim(PR_NEG));              // 表が壊れていても型を調べる
    prog.push_back(w_table());
    prog.push_back(w(OP_SEND0, 1, 30));
    run();
    expect_error(1);

    begin_test("Proc#call and lambda");
    method_entry(CLS_PROC, 23, tgt_prim(PR_CALL));
    method_entry(CLS_OBJECT, 24, tgt_prim(PR_LAMBDA));
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_BLOCK, 1, 8));                       // 1: R1 = proc { |x| x + 1 }
    prog.push_back(w(OP_LOADI_4, 2));                        // 2
    prog.push_back(w(OP_SEND, 1, 23, 1));                    // 3: R1 = R1.call(4) = 5
    prog.push_back(w(OP_BLOCK, 3, 8));                       // 4: R3 = 同じブロック
    prog.push_back(w(OP_SSEND, 2, 24, 8'h80));               // 5: R2 = lambda(&R3)
    prog.push_back(w(OP_SEND0, 2, 23));                      // 6: lambda を引数 0 個で呼ぶ
    prog.push_back(w(OP_STOP));                              // 7
    prog.push_back(w(OP_ENTER, 1, 3));                       // 8: |x| (lambda なら数が違うとここでエラー)
    prog.push_back(w(OP_ADDI, 1, 1));                        // 9
    prog.push_back(w(OP_RETURN, 1));                         // 10
    run();
    expect_error(8);
    expect_reg(1, vint(5));

    // ---- Proc (BLOCK / BLKCALL): 外側の変数と break
    begin_test("proc, upvar and break");
    prog.push_back(w(OP_LOADI_5, 1));                        // 0: 外側の R1 = 5
    prog.push_back(w(OP_BLOCK, 3, 6));                       // 1: R3 = Proc (先頭 pc 6)
    prog.push_back(w(OP_BLKCALL, 3, 0));                     // 2: ブロックのフレームは bp + 3
    prog.push_back(w(OP_LOADI_7, 2));                        // 3: (break で飛ばされる)
    prog.push_back(w(OP_STOP));                              // 4: break の出口
    prog.push_back(w(OP_STOP));                              // 5
    prog.push_back(w(OP_ENTER, 0, 4));                       // 6: 引数 0、nregs 4
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 7: R1 = 作ったフレームの R1
    prog.push_back(w(OP_ADDI, 1, 1));                        // 8
    prog.push_back(w(OP_SETUPVAR, 1, 1, 1));                 // 9: 作ったフレームの R1 = 6
    prog.push_back(w(OP_BREAK, 1, 4, 0));                    // 10: 値 6 を持って出口 (pc 4) へ
    run();
    expect_halt();
    expect_reg(1, vint(6));
    expect_reg(2, VNIL);                                     // pc 3 は通らない
    expect_reg(3, vint(6));                                  // break の値はブロックのフレームの R0 (= 外側の R3)
    expect_reg(4, vint(6));                                  // ブロックの R1
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after break", name, dut.core.sp, dut.core.bp);

    begin_test("yield through a method and dynamic break");
    method_entry(CLS_NIL, 20, 16'd5);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_BLOCK, 2, 8));                       // 1: R2 = Proc (先頭 pc 8)
    prog.push_back(w(OP_SSEND, 1, 20, 8'h80 | 0));           // 2: m(&blk)。ブロックの枠 (R1 + 1) を残す
    prog.push_back(w(OP_STOP));                              // 3: break の戻り先
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_BLKPUSH, 2, 1, 0));                  // 5: m: R2 = 自分のブロック (枠 1)
    prog.push_back(w(OP_LOADI_4, 3));                        // 6: yield 4
    prog.push_back(w(OP_BLKCALL, 2, 1));                     // 7
    prog.push_back(w(OP_ENTER, 1, 3));                       // 8: ブロック |x|
    prog.push_back(w(OP_ADDI, 1, 2));                        // 9: R1 (= 4) + 2
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 10: Proc を作ったフレームまで畳む
    run();
    expect_halt();
    expect_reg(1, vint(6));                                  // m(...) の結果が break の値
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after break", name, dut.core.sp, dut.core.bp);

    // ---- 配列 (ヒープ)
    begin_test("arrays");
    method_entry(CLS_ARRAY, 40, tgt_prim(PR_SIZE));
    method_entry(CLS_ARRAY, 41, tgt_prim(PR_POP));
    method_entry(CLS_ARRAY, 42, tgt_prim(PR_LAST));
    method_entry(CLS_ARRAY, 43, tgt_prim(PR_PUSH));
    method_entry(CLS_ARRAY, 44, tgt_prim(PR_LENGTH));
    method_entry(CLS_ARRAY, 45, tgt_prim(PR_FIRST));
    method_entry(CLS_ARRAY, 46, tgt_prim(PR_EMPTY));
    method_entry(CLS_ARRAY, 47, tgt_prim(PR_AGET));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_3, 1));                        // 1
    prog.push_back(w(OP_LOADI_1, 2));                        // 2
    prog.push_back(w(OP_LOADI_4, 3));                        // 3
    prog.push_back(w(OP_ARRAY2, 4, 1, 3));                   // 4: R4 = [3, 1, 4]
    prog.push_back(w(OP_MOVE, 5, 4));                        // 5
    prog.push_back(w(OP_LOADI__1, 6));                       // 6
    prog.push_back(w(OP_GETIDX, 5));                         // 7: R5 = a[-1] = 4
    prog.push_back(w(OP_GETIDX0, 6, 4));                     // 8: R6 = a[0] = 3
    prog.push_back(w(OP_MOVE, 7, 4));                        // 9
    prog.push_back(w(OP_LOADI_5, 8));                        // 10
    prog.push_back(w(OP_LOADI_7, 9));                        // 11
    prog.push_back(w(OP_SETIDX, 7));                         // 12: a[5] = 7 (容量を超えて伸ばす)
    prog.push_back(w(OP_MOVE, 10, 4));                       // 13
    prog.push_back(w(OP_SEND0, 10, 40));                     // 14: R10 = a.size = 6
    prog.push_back(w(OP_MOVE, 11, 4));                       // 15
    prog.push_back(w(OP_SEND0, 11, 41));                     // 16: R11 = a.pop = 7
    prog.push_back(w(OP_MOVE, 12, 4));                       // 17
    prog.push_back(w(OP_SEND0, 12, 42));                     // 18: R12 = a.last = nil (a[4])
    prog.push_back(w(OP_MOVE, 13, 4));                       // 19
    prog.push_back(w(OP_LOADI_1, 14));                       // 20
    prog.push_back(w(OP_SEND, 13, 43, 1));                   // 21: a.push(1) は a を返す
    prog.push_back(w(OP_MOVE, 14, 4));                       // 22
    prog.push_back(w(OP_SEND0, 14, 44));                     // 23: R14 = a.length = 6
    prog.push_back(w(OP_MOVE, 8, 4));                        // 24
    prog.push_back(w(OP_LOADI_2, 9));                        // 25
    prog.push_back(w(OP_SEND, 8, 47, 1));                    // 26: R8 = a[2] (Array#[]) = 4
    prog.push_back(w(OP_MOVE, 1, 4));                        // 27
    prog.push_back(w(OP_SEND0, 1, 45));                      // 28: R1 = a.first = 3
    prog.push_back(w(OP_ARRAY, 2, 0));                       // 29: R2 = []
    prog.push_back(w(OP_SEND0, 2, 46));                      // 30: R2 = [].empty? = true
    prog.push_back(w(OP_LOADI_5, 3));                        // 31
    prog.push_back(w(OP_ARRAY, 3, 1));                       // 32: R3 = [5]
    prog.push_back(w(OP_GETIDX0, 3, 3));                     // 33: R3 = 5
    prog.push_back(w(OP_STOP));                              // 34
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
    expect_reg(8, vint(4));
    expect_reg(1, vint(3));
    expect_reg(2, VTRUE);
    expect_reg(3, vint(5));

    begin_test("Array#[]= returns the value");
    method_entry(CLS_ARRAY, 48, tgt_prim(PR_ASET));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_ARRAY, 1, 0));                       // 1: R1 = []
    prog.push_back(w(OP_MOVE, 4, 1));                        // 2
    prog.push_back(w(OP_LOADI_2, 2));                        // 3
    prog.push_back(w(OP_LOADI_7, 3));                        // 4
    prog.push_back(w(OP_SEND, 1, 48, 2));                    // 5: R1 = (a[2] = 7) = 7
    prog.push_back(w(OP_LOADI_2, 5));                        // 6
    prog.push_back(w(OP_GETIDX, 4));                         // 7: R4 = a[2] = 7
    prog.push_back(w(OP_STOP));                              // 8
    run();
    expect_halt();
    expect_reg(1, vint(7));
    expect_reg(4, vint(7));

    begin_test("== on objects sends ==");
    method_entry(CLS_ARRAY, SUPER_SYM, CLS_OBJECT);
    method_entry(CLS_OBJECT, SYM_EQ, tgt_prim(PR_OEQ));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_ARRAY, 1, 0));                       // 1
    prog.push_back(w(OP_MOVE, 2, 1));                        // 2
    prog.push_back(w(OP_EQ, 1));                             // 3: 同じ配列 → true (Object#==)
    prog.push_back(w(OP_ARRAY, 3, 0));                       // 4
    prog.push_back(w(OP_ARRAY, 4, 0));                       // 5
    prog.push_back(w(OP_EQ, 3));                             // 6: 別の配列 → false
    prog.push_back(w(OP_STOP));                              // 7
    run();
    expect_halt();
    expect_reg(1, VTRUE);
    expect_reg(3, VFALSE);

    begin_test("== on objects without a method table is an error");
    prog.push_back(w(OP_ARRAY, 1, 0));
    prog.push_back(w(OP_MOVE, 2, 1));
    prog.push_back(w(OP_EQ, 1));
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
    method_entry(CLS_NIL, 20, 16'd4);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 1: R1 = m
    prog.push_back(w(OP_STOP));                              // 2
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_LOADI_1, 1));                        // 4: m
    prog.push_back(w(OP_BLOCK, 2, 9));                       // 5
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 6
    prog.push_back(w(OP_LOADI_7, 1));                        // 7: (通らない)
    prog.push_back(w(OP_RETURN, 1));                         // 8
    prog.push_back(w(OP_ENTER, 0, 3));                       // 9: ブロック
    prog.push_back(w(OP_LOADI8, 1, 9));                      // 10: return 9
    prog.push_back(w(OP_RETURN_BLK, 1, 0, 1));               // 11: 1段外のメソッドから戻る
    run();
    expect_halt();
    expect_reg(1, vint(9));
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d after return", name, dut.core.sp, dut.core.bp);

    // ---- 時間待ち: sleep_ms n は ms_tick を n 回数えて n を返す
    begin_test("sleep_ms 0");
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);
    method_entry(CLS_OBJECT, 50, tgt_prim(PR_SLEEPMS));
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI_0, 2));                        // self (R1) は nil、引数は R2
    prog.push_back(w(OP_SEND, 1, 50, 1));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(0));
    base_cycles = cycles;

    begin_test("sleep_ms 100");
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);
    method_entry(CLS_OBJECT, 50, tgt_prim(PR_SLEEPMS));
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI8, 2, 100));
    prog.push_back(w(OP_SEND, 1, 50, 1));
    prog.push_back(w(OP_STOP));
    run();
    expect_halt();
    expect_reg(1, vint(100));
    if (cycles - base_cycles < 100 || cycles - base_cycles > 110)
      $fatal(1, "%s: waited %0d cycles more than sleep_ms 0 (ms_tick every cycle)", name, cycles - base_cycles);

    begin_test("sleep with a negative time");
    method_entry(CLS_NIL, SUPER_SYM, CLS_OBJECT);
    method_entry(CLS_OBJECT, 51, tgt_prim(PR_SLEEP));
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI__1, 2));
    prog.push_back(w(OP_SEND, 1, 51, 1));
    run();
    expect_error(2);

    // ---- env: メソッドから戻った後も、その変数を Proc から読み書きできる
    begin_test("closure outlives its method");
    method_entry(CLS_NIL, 20, 16'd8);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 1: R1 = m (Proc が返る)
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 2: R1 = 6 (env の R1 を 5 から 6 に)
    prog.push_back(w(OP_MOVE, 6, 1));                        // 3: R6 = 6 (2本目の呼び出しのフレームより上)
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 4: 別の env
    prog.push_back(w(OP_MOVE, 2, 1));                        // 5: R2 = 2本目の Proc
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 6: R2 = 6 (1本目とは別の env)
    prog.push_back(w(OP_STOP));                              // 7
    prog.push_back(w(OP_ENTER, 0, 3));                       // 8: m (nregs 3: env に写すのは R0..R2)
    prog.push_back(w(OP_LOADI_5, 1));                        // 9: R1 = 5
    prog.push_back(w(OP_BLOCK, 2, 12));                      // 10: R2 = Proc (env を作る)
    prog.push_back(w(OP_RETURN, 2));                         // 11: 戻る時に env へ R0..R2 を写す
    prog.push_back(w(OP_ENTER, 0, 3));                       // 12: ブロック
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 13: R1 = env の R1
    prog.push_back(w(OP_ADDI, 1, 1));                        // 14
    prog.push_back(w(OP_SETUPVAR, 1, 1, 1));                 // 15: env の R1 = R1 (ヒープへ)
    prog.push_back(w(OP_RETURN, 1));                         // 16
    run();
    expect_halt();
    expect_reg(6, vint(6));
    expect_reg(2, vint(6));                                  // 2本目は別の env (5 から数え直す)

    begin_test("break to a method that has returned");
    method_entry(CLS_NIL, 20, 16'd4);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 1
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 2: break の行き先のフレームはもう無い
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_ENTER, 0, 3));                       // 4: m
    prog.push_back(w(OP_BLOCK, 2, 7));                       // 5
    prog.push_back(w(OP_RETURN, 2));                         // 6
    prog.push_back(w(OP_ENTER, 0, 3));                       // 7
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 8
    run();
    expect_error(8);

    // ---- lambda: 引数の数を (先頭の ENTER が) 調べ、break / return は lambda から戻る
    begin_test("lambda checks the number of arguments");
    prog.push_back(w(OP_BLOCK, 1, 3, 8'h80));                // 0: lambda { |x| }
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: 引数 0 個
    prog.push_back(w(OP_RETNIL));                            // 2
    prog.push_back(w(OP_ENTER, 1, 3));                       // 3: ここでエラー
    prog.push_back(w(OP_RETNIL));                            // 4
    run();
    expect_error(3);

    begin_test("break in a lambda");
    prog.push_back(w(OP_BLOCK, 1, 5, 8'h80));                // 0: lambda { |x| break x + 1 }
    prog.push_back(w(OP_LOADI_4, 2));                        // 1
    prog.push_back(w(OP_BLKCALL, 1, 1));                     // 2: R1 = 5
    prog.push_back(w(OP_LOADI_7, 3));                        // 3: 通る (lambda から戻っただけ)
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_ENTER, 1, 3));                       // 5
    prog.push_back(w(OP_ADDI, 1, 1));                        // 6
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 7
    run();
    expect_halt();
    expect_reg(1, vint(5));
    expect_reg(3, vint(7));

    begin_test("return in a proc inside a lambda");
    prog.push_back(w(OP_BLOCK, 1, 4, 8'h80));                // 0: l = lambda { proc { return 9 }.call; 1 }
    prog.push_back(w(OP_BLKCALL, 1, 0));                     // 1: R1 = 9
    prog.push_back(w(OP_LOADI_7, 2));                        // 2
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_ENTER, 0, 4));                       // 4: lambda の中
    prog.push_back(w(OP_BLOCK, 2, 9));                       // 5: proc
    prog.push_back(w(OP_BLKCALL, 2, 0));                     // 6
    prog.push_back(w(OP_LOADI_1, 1));                        // 7: (通らない)
    prog.push_back(w(OP_RETURN, 1));                         // 8
    prog.push_back(w(OP_ENTER, 0, 3));                       // 9: proc の中
    prog.push_back(w(OP_LOADI8, 1, 9));                      // 10
    prog.push_back(w(OP_RETURN_BLK, 1, 0, 2));               // 11: 深さ 1 の lambda から戻る
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

    // ---- オブジェクト: Q < P。new が確保して initialize を呼び (戻り値は捨てる)、インスタンス変数は
    //      (クラス, @名前) の番号で読み書きする。attr は IVAR / IVSET の行、super は見つかったクラスの親から引く
    begin_test("objects, attr, super, is_a?, respond_to?");
    method_entry(16'd32, NIVARS_SYM, 16'd2);
    method_entry(16'd32, 16'd40, {TGT_IVAR, 14'd0});         // @a
    method_entry(16'd32, 16'd41, {TGT_IVAR, 14'd1});         // @b
    method_entry(16'd32, SYM_INIT, 16'd27);
    method_entry(16'd32, 16'd42, {TGT_IVAR, 14'd0});         // attr_reader :a
    method_entry(16'd32, 16'd43, {TGT_IVSET, 14'd1});        // attr_writer :b
    method_entry(16'd32, 16'd46, {TGT_IVAR, 14'd1});         // attr_reader :b
    method_entry(16'd32, 16'd45, 16'd33);                    // P#get
    method_entry(16'd32, SUPER_SYM, CLS_OBJECT);
    method_entry(16'd33, SUPER_SYM, 16'd32);
    method_entry(16'd33, NIVARS_SYM, 16'd2);
    method_entry(16'd33, 16'd45, 16'd36);                    // Q#get
    method_entry(CLS_META | 16'd33, 16'd44, tgt_prim(PR_NEW));
    method_entry(CLS_OBJECT, 16'd47, tgt_prim(PR_ISA));
    method_entry(CLS_OBJECT, 16'd48, tgt_prim(PR_RESPOND));
    method_entry(ISA_BIT | 16'd33, 16'd32, 16'd1);           // Q.is_a?(P)
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_CLASS, 1, 33));                      // 1
    prog.push_back(w(OP_LOADI_5, 2));                        // 2
    prog.push_back(w(OP_SEND, 1, 44, 1));                    // 3: R1 = Q.new(5)
    prog.push_back(w(OP_MOVE, 3, 1));                        // 4
    prog.push_back(w(OP_SEND0, 3, 42));                      // 5: R3 = 5
    prog.push_back(w(OP_MOVE, 4, 1));                        // 6
    prog.push_back(w(OP_SEND0, 4, 45));                      // 7: R4 = 105 (Q#get -> super -> P#get)
    prog.push_back(w(OP_MOVE, 5, 1));                        // 8
    prog.push_back(w(OP_LOADI_3, 6));                        // 9
    prog.push_back(w(OP_SEND, 5, 43, 1));                    // 10: R5 = (b = 3)
    prog.push_back(w(OP_MOVE, 7, 1));                        // 11
    prog.push_back(w(OP_SEND0, 7, 46));                      // 12: R7 = 3
    prog.push_back(w(OP_MOVE, 8, 1));                        // 13
    prog.push_back(w(OP_CLASS, 9, 32));                      // 14
    prog.push_back(w(OP_SEND, 8, 47, 1));                    // 15: true
    prog.push_back(w(OP_MOVE, 10, 1));                       // 16
    prog.push_back(w(OP_CLASS, 11, CLS_NIL));                // 17
    prog.push_back(w(OP_SEND, 10, 47, 1));                   // 18: false
    prog.push_back(w(OP_MOVE, 12, 1));                       // 19
    prog.push_back(w(OP_LOADSYM, 13, 45));                   // 20
    prog.push_back(w(OP_SEND, 12, 48, 1));                   // 21: true (Q#get)
    prog.push_back(w(OP_MOVE, 13, 1));                       // 22: (tb は16レジスタ)
    prog.push_back(w(OP_LOADSYM, 14, 99));                   // 23
    prog.push_back(w(OP_SEND, 13, 48, 1));                   // 24: false
    prog.push_back(w(OP_GETIV, 15, 40));                     // 25: self は nil、行が無いので nil
    prog.push_back(w(OP_STOP));                              // 26
    prog.push_back(w(OP_ENTER, 1, 4));                       // 27: initialize(x)
    prog.push_back(w(OP_SETIV, 1, 40));                      // 28: @a = x
    prog.push_back(w(OP_LOADI_7, 3));                        // 29
    prog.push_back(w(OP_SETIV, 3, 41));                      // 30: @b = 7
    prog.push_back(w(OP_LOADI8, 3, 99));                     // 31
    prog.push_back(w(OP_RETURN, 3));                         // 32: 99 は捨てる
    prog.push_back(w(OP_ENTER, 0, 3));                       // 33: P#get
    prog.push_back(w(OP_GETIV, 1, 40));                      // 34
    prog.push_back(w(OP_RETURN, 1));                         // 35
    prog.push_back(w(OP_ENTER, 0, 3));                       // 36: Q#get
    prog.push_back(w(OP_SUPER, 1, 45, 16'h80));              // 37
    prog.push_back(w(OP_ADDI, 1, 100));                      // 38
    prog.push_back(w(OP_RETURN, 1));                         // 39
    run();
    expect_halt();
    if (dut.core.regs[1][VAL_BITS-1 -: TAG_BITS] != TAG_OBJ) $fatal(1, "%s: R1 is not an object", name);
    expect_reg(3, vint(5));
    expect_reg(4, vint(105));
    expect_reg(5, vint(3));
    expect_reg(7, vint(3));
    expect_reg(8, VTRUE);
    expect_reg(10, VFALSE);
    expect_reg(12, VTRUE);
    expect_reg(13, VFALSE);
    expect_reg(15, VNIL);
    if (dut.core.sp != 0 || dut.core.bp != 0) $fatal(1, "%s: sp=%0d bp=%0d at the end", name, dut.core.sp, dut.core.bp);

    begin_test("SETIV without a slot");
    prog.push_back(w_table());
    prog.push_back(w(OP_LOADI_1, 1));
    prog.push_back(w(OP_SETIV, 1, 40));                      // nil にインスタンス変数は無い
    run();
    expect_error(2);

    begin_test("new on a built-in class");
    method_entry(CLS_META | CLS_INT, 16'd44, tgt_prim(PR_NEW));
    prog.push_back(w_table());
    prog.push_back(w(OP_CLASS, 1, CLS_INT));
    prog.push_back(w(OP_SEND0, 1, 44));                      // Integer.new は作れない
    run();
    expect_error(2);

    // ---- 引数: f(a, b = 5, *r, c) は ((a * 10 + b) * 10 + r.size) * 10 + c。ENTER の c = o | r << 5 | m2 << 6、
    //      後ろに省略可能な引数の JMP の表 (o + 1 語)。splat の呼び出しは引数の数 15 (R[a+1] が配列)
    begin_test("optional, rest and post arguments, splat call");
    method_entry(CLS_NIL, 20, 16'd16);
    method_entry(CLS_ARRAY, 40, tgt_prim(PR_SIZE));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_1, 2));                        // 1
    prog.push_back(w(OP_LOADI_2, 3));                        // 2
    prog.push_back(w(OP_SSEND, 1, 20, 2));                   // 3: R1 = f(1, 2) (b = 5)
    prog.push_back(w(OP_LOADI_1, 3));                        // 4
    prog.push_back(w(OP_LOADI_2, 4));                        // 5
    prog.push_back(w(OP_LOADI_3, 5));                        // 6
    prog.push_back(w(OP_LOADI_4, 6));                        // 7
    prog.push_back(w(OP_LOADI_5, 7));                        // 8
    prog.push_back(w(OP_SSEND, 2, 20, 5));                   // 9: R2 = f(1, 2, 3, 4, 5)
    prog.push_back(w(OP_LOADI_7, 4));                        // 10
    prog.push_back(w(OP_LOADI8, 5, 8));                      // 11
    prog.push_back(w(OP_LOADI8, 6, 9));                      // 12
    prog.push_back(w(OP_ARRAY, 4, 3));                       // 13: R4 = [7, 8, 9]
    prog.push_back(w(OP_SSEND, 3, 20, 15));                  // 14: R3 = f(*R4)
    prog.push_back(w(OP_STOP));                              // 15
    prog.push_back(w(OP_ENTER, 1, 8, 1 | (1 << 5) | (1 << 6))); // 16: f
    prog.push_back(w(OP_JMP, 0, 19));                        // 17: b を渡されていない
    prog.push_back(w(OP_JMP, 0, 20));                        // 18: 渡された
    prog.push_back(w(OP_LOADI_5, 2));                        // 19: b = 5
    prog.push_back(w(OP_MOVE, 6, 1));                        // 20: R5 はブロックの枠
    prog.push_back(w(OP_LOADI8, 7, 10));                     // 21
    prog.push_back(w(OP_MUL, 6));                            // 22
    prog.push_back(w(OP_MOVE, 7, 2));                        // 23
    prog.push_back(w(OP_ADD, 6));                            // 24
    prog.push_back(w(OP_LOADI8, 7, 10));                     // 25
    prog.push_back(w(OP_MUL, 6));                            // 26
    prog.push_back(w(OP_MOVE, 7, 3));                        // 27
    prog.push_back(w(OP_SEND0, 7, 40));                      // 28: r.size
    prog.push_back(w(OP_ADD, 6));                            // 29
    prog.push_back(w(OP_LOADI8, 7, 10));                     // 30
    prog.push_back(w(OP_MUL, 6));                            // 31
    prog.push_back(w(OP_MOVE, 7, 4));                        // 32
    prog.push_back(w(OP_ADD, 6));                            // 33
    prog.push_back(w(OP_RETURN, 6));                         // 34
    run();
    expect_halt();
    expect_reg(1, vint(1502));
    expect_reg(2, vint(1225));
    expect_reg(3, vint(7809));

    begin_test("too few arguments");
    method_entry(CLS_NIL, 20, 16'd3);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 1: f() に必須が 1 つ
    prog.push_back(w(OP_STOP));                              // 2
    prog.push_back(w(OP_ENTER, 1, 4, 1 << 5));               // 3: f(a, *r)
    prog.push_back(w(OP_RETNIL));                            // 4
    run();
    expect_error(3);

    // ---- 配列の展開: [*a] (ARYCAT)、[*a, x] (ARYPUSH)、a, *b, c = v (APOST)
    begin_test("array splats");
    prog.push_back(w(OP_LOADI_1, 1));                        // 0
    prog.push_back(w(OP_LOADI_2, 2));                        // 1
    prog.push_back(w(OP_ARRAY, 1, 2));                       // 2: R1 = [1, 2]
    prog.push_back(w(OP_LOADNIL, 2));                        // 3
    prog.push_back(w(OP_MOVE, 3, 1));                        // 4
    prog.push_back(w(OP_ARYCAT, 2));                         // 5: R2 = [*R1] (写し)
    prog.push_back(w(OP_LOADI_3, 3));                        // 6
    prog.push_back(w(OP_LOADI_4, 4));                        // 7
    prog.push_back(w(OP_ARYPUSH, 2, 2));                     // 8: R2 = [1, 2, 3, 4]
    prog.push_back(w(OP_MOVE, 3, 2));                        // 9
    prog.push_back(w(OP_LOADI_5, 4));                        // 10
    prog.push_back(w(OP_ARYCAT, 3));                         // 11: R3 = [*R2, *5] = [1, 2, 3, 4, 5]
    prog.push_back(w(OP_MOVE, 4, 3));                        // 12
    prog.push_back(w(OP_APOST, 4, 1, 2));                    // 13: _, *R4, R5, R6 = R3 -> [2, 3], 4, 5
    prog.push_back(w(OP_LOADI_7, 7));                        // 14
    prog.push_back(w(OP_APOST, 7, 0, 1));                    // 15: *R7, R8 = 7 -> [], 7
    prog.push_back(w(OP_AREF, 9, 4, 1));                     // 16: R9 = R4[1]
    prog.push_back(w(OP_AREF, 10, 3, 4));                    // 17: R10 = R3[4]
    prog.push_back(w(OP_AREF, 11, 7, 0));                    // 18: R11 = R7[0] (空)
    prog.push_back(w(OP_AREF, 12, 1, 1));                    // 19: R12 = R1[1] (元は変わらない)
    prog.push_back(w(OP_STOP));                              // 20
    run();
    expect_halt();
    expect_reg(5, vint(4));
    expect_reg(6, vint(5));
    expect_reg(8, vint(7));
    expect_reg(9, vint(3));
    expect_reg(10, vint(5));
    expect_reg(11, VNIL);
    expect_reg(12, vint(2));

    // ---- 引数なしの super の引数 (ARGARY): g(a, *r) の中で R4 = [a, *r]、R5 = ブロック
    begin_test("argary");
    method_entry(CLS_NIL, 20, 16'd7);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_1, 2));                        // 1
    prog.push_back(w(OP_LOADI_2, 3));                        // 2
    prog.push_back(w(OP_LOADI_3, 4));                        // 3
    prog.push_back(w(OP_SSEND, 1, 20, 3));                   // 4: R1 = g(1, 2, 3)
    prog.push_back(w(OP_AREF, 2, 1, 2));                     // 5: R2 = R1[2]
    prog.push_back(w(OP_STOP));                              // 6
    prog.push_back(w(OP_ENTER, 1, 6, 1 << 5));               // 7: g(a, *r)
    prog.push_back(w(OP_ARGARY, 4, (1 << 11) | (1 << 10)));  // 8: 1:1:0:0
    prog.push_back(w(OP_RETURN, 4));                         // 9
    run();
    expect_halt();
    expect_reg(2, vint(3));

    // ---- proc は引数が1つの配列なら展開する (|a, b| に [4, 5])。lambda は展開しない
    begin_test("proc auto-splat");
    prog.push_back(w(OP_BLOCK, 1, 7));                       // 0: proc { |a, b| a * 10 + b }
    prog.push_back(w(OP_LOADI_4, 2));                        // 1
    prog.push_back(w(OP_LOADI_5, 3));                        // 2
    prog.push_back(w(OP_ARRAY, 2, 2));                       // 3: R2 = [4, 5]
    prog.push_back(w(OP_BLKCALL, 1, 1));                     // 4: R1 = 45
    prog.push_back(w(OP_STOP));                              // 5
    prog.push_back(w(OP_STOP));                              // 6
    prog.push_back(w(OP_ENTER, 2, 5));                       // 7: R1 = a、R2 = b、R3 はブロックの枠
    prog.push_back(w(OP_MOVE, 4, 2));                        // 8
    prog.push_back(w(OP_LOADI8, 2, 10));                     // 9
    prog.push_back(w(OP_MUL, 1));                            // 10: R1 = a * 10
    prog.push_back(w(OP_MOVE, 2, 4));                        // 11
    prog.push_back(w(OP_ADD, 1));                            // 12
    prog.push_back(w(OP_RETURN, 1));                         // 13
    run();
    expect_halt();
    expect_reg(1, vint(45));

    // ---- String: ROM のデータ (1語 4バイト) から作る。bytesize / getbyte / __aset / __push / __slice、
    //      Symbol#to_s (シンボル表は TABLE の c)、Module#__name_sym ((クラス, NAME_SYM) の行)
    begin_test("strings");
    method_entry(CLS_STRING, 40, tgt_prim(PR_SBYTES));
    method_entry(CLS_STRING, 41, tgt_prim(PR_SGETB));
    method_entry(CLS_STRING, 42, tgt_prim(PR_SASET));
    method_entry(CLS_STRING, 43, tgt_prim(PR_SPUSH));
    method_entry(CLS_STRING, 44, tgt_prim(PR_SSLICE));
    method_entry(CLS_SYM, 45, tgt_prim(PR_SYMSTR));
    method_entry(CLS_META | CLS_INT, 46, tgt_prim(PR_NAMESYM));
    method_entry(CLS_META | CLS_ARRAY, 46, tgt_prim(PR_NAMESYM));
    method_entry(CLS_INT, NAME_SYM, 16'd3);                  // Integer の名前は :s3
    prog.push_back(w(OP_TABLE, TB_LOG, TB_BASE, 44));        // 0: シンボル表は 44
    prog.push_back(w(OP_STRING, 1, 40, 5));                  // 1: R1 = "hello"
    prog.push_back(w(OP_MOVE, 2, 1));                        // 2
    prog.push_back(w(OP_SEND0, 2, 40));                      // 3: R2 = 5
    prog.push_back(w(OP_MOVE, 3, 1));                        // 4
    prog.push_back(w(OP_LOADI_1, 4));                        // 5
    prog.push_back(w(OP_SEND, 3, 41, 1));                    // 6: R3 = 'e'
    prog.push_back(w(OP_MOVE, 4, 1));                        // 7
    prog.push_back(w(OP_LOADI_0, 5));                        // 8
    prog.push_back(w(OP_LOADI8, 6, 72));                     // 9
    prog.push_back(w(OP_SEND, 4, 42, 2));                    // 10: R1[0] = 'H'
    prog.push_back(w(OP_MOVE, 5, 1));                        // 11
    prog.push_back(w(OP_LOADI8, 6, 33));                     // 12
    prog.push_back(w(OP_SEND, 5, 43, 1));                    // 13: R1 << '!' (伸ばす)
    prog.push_back(w(OP_MOVE, 6, 1));                        // 14
    prog.push_back(w(OP_LOADI_1, 7));                        // 15
    prog.push_back(w(OP_LOADI_3, 8));                        // 16
    prog.push_back(w(OP_SEND, 6, 44, 2));                    // 17: R6 = "ell"
    prog.push_back(w(OP_MOVE, 7, 6));                        // 18
    prog.push_back(w(OP_SEND0, 7, 40));                      // 19: R7 = 3
    prog.push_back(w(OP_MOVE, 8, 1));                        // 20
    prog.push_back(w(OP_LOADI_5, 9));                        // 21
    prog.push_back(w(OP_SEND, 8, 41, 1));                    // 22: R8 = '!'
    prog.push_back(w(OP_LOADSYM, 9, 1));                     // 23
    prog.push_back(w(OP_SEND0, 9, 45));                      // 24: R9 = :s1.to_s = "ab"
    prog.push_back(w(OP_MOVE, 10, 9));                       // 25
    prog.push_back(w(OP_LOADI_1, 11));                       // 26
    prog.push_back(w(OP_SEND, 10, 41, 1));                   // 27: R10 = 'b'
    prog.push_back(w(OP_CLASS, 11, CLS_INT));                // 28
    prog.push_back(w(OP_SEND0, 11, 46));                     // 29: R11 = :s3
    prog.push_back(w(OP_CLASS, 12, CLS_ARRAY));              // 30
    prog.push_back(w(OP_SEND0, 12, 46));                     // 31: R12 = nil (行が無い)
    prog.push_back(w(OP_MOVE, 13, 1));                       // 32
    prog.push_back(w(OP_SEND0, 13, 40));                     // 33: R13 = 6
    prog.push_back(w(OP_STOP));                              // 34
    while (prog.size() < 40) prog.push_back(w(OP_NOP));
    prog.push_back(48'h0000_6c6c_6568);                      // 40: "hell"
    prog.push_back(48'h0000_0000_006f);                      // 41: "o"
    prog.push_back(48'h0000_0000_6261);                      // 42: "ab"
    prog.push_back(w(OP_NOP));                               // 43
    prog.push_back({16'd0, 16'd40, 16'd5});                  // 44: :s0 = "hello"
    prog.push_back({16'd0, 16'd42, 16'd2});                  // 45: :s1 = "ab"
    run();
    expect_halt();
    expect_reg(2, vint(5));
    expect_reg(3, vint(101));
    expect_reg(4, vint(72));
    expect_reg(7, vint(3));
    expect_reg(8, vint(33));
    expect_reg(10, vint(98));
    expect_reg(11, {TAG_SYM, 32'd3});
    expect_reg(12, VNIL);
    expect_reg(13, vint(6));

    begin_test("string byte out of range");
    method_entry(CLS_STRING, 43, tgt_prim(PR_SPUSH));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_STRING, 1, 0, 0));                   // 1: R1 = ""
    prog.push_back(w(OP_LOADI16, 2, 256));                   // 2
    prog.push_back(w(OP_SEND, 1, 43, 1));                    // 3: 256 は1バイトでない
    run();
    expect_error(3);

    // ---- キーワード引数: 印 KW (c の bit 8) 付きの呼び出しは R[a+1] に Hash、ブロックはその次。
    //      ENTER の kd (c の bit 11) は R[len+1] に Hash (渡されなければ空の Hash を作る)、kd でなければ最後の引数として数える
    begin_test("keyword arguments");
    method_entry(CLS_NIL, 20, 16'd11);
    method_entry(CLS_NIL, 21, 16'd13);
    method_entry(CLS_NIL, 22, 16'd15);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI8, 2, 42));                     // 1: 渡す Hash の代わり (回路は型を見ない)
    prog.push_back(w(OP_SSEND, 1, 20, 16'h100));             // 2: R1 = f(**42)
    prog.push_back(w(OP_SSEND0, 3, 20));                     // 3: R3 = f() (空の Hash)
    prog.push_back(w(OP_LOADI8, 5, 43));                     // 4
    prog.push_back(w(OP_SSEND, 4, 21, 16'h100));             // 5: R4 = g(**43) (kd でない: 引数 1 個になる)
    prog.push_back(w(OP_LOADI8, 7, 44));                     // 6
    prog.push_back(w(OP_BLOCK, 8, 17));                      // 7
    prog.push_back(w(OP_NOP));                               // 8
    prog.push_back(w(OP_SSEND, 6, 22, 16'h180));             // 9: R6 = h(**44, &R8) (ブロックは Hash の次)
    prog.push_back(w(OP_STOP));                              // 10
    prog.push_back(w(OP_ENTER, 0, 5, 16'h800));              // 11: f(**k)
    prog.push_back(w(OP_RETURN, 1));                         // 12
    prog.push_back(w(OP_ENTER, 1, 4));                       // 13: g(a)
    prog.push_back(w(OP_RETURN, 1));                         // 14
    prog.push_back(w(OP_ENTER, 0, 5, 16'h800));              // 15: h(**k, &b)
    prog.push_back(w(OP_RETURN, 2));                         // 16
    prog.push_back(w(OP_ENTER, 0, 3));                       // 17: ブロック
    prog.push_back(w(OP_RETNIL));                            // 18
    run();
    expect_halt();
    expect_reg(1, vint(42));
    expect_reg(4, vint(43));
    if (dut.core.regs[3][VAL_BITS-1 -: TAG_BITS] != TAG_OBJ || dut.core.heap[dut.core.regs[3][10:0]] !== {TAG_HDR, CLS_HASH, 16'd4})
      $fatal(1, "%s: R3 is not an empty Hash", name);
    if (dut.core.regs[6] !== dut.core.regs[8] || dut.core.regs[6][VAL_BITS-1 -: TAG_BITS] != TAG_OBJ) $fatal(1, "%s: the block did not reach h", name);

    begin_test("upvar below the register file");
    prog.push_back(w(OP_GETUPVAR, 1, 1, 1));                 // 一番外では Proc が無い
    run();
    expect_error(0);

    begin_test("break outside a block");
    prog.push_back(w(OP_BREAK, 1, 0));
    run();
    expect_error(0);

    // ---- 例外と巻き戻し: 例外の表 (HTABLE の b から c 語、1語 = {種類 << 15 | 飛び先, begin, end}) を pc 200 から置く
    begin_test("raise and rescue across frames");
    method_entry(CLS_NIL, 20, 16'd9);
    method_entry(CLS_NIL, 21, tgt_prim(PR_RAISE));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_HTABLE, 0, 200, 1));                 // 1
    prog.push_back(w(OP_LOADI_1, 1));                        // 2
    prog.push_back(w(OP_SSEND0, 2, 20));                     // 3: f (rescue [3, 4) -> 6)
    prog.push_back(w(OP_LOADI_5, 3));                        // 4: 通らない
    prog.push_back(w(OP_STOP));                              // 5
    prog.push_back(w(OP_EXCEPT, 4));                         // 6: R4 = 投げたもの
    prog.push_back(w(OP_LOADI_7, 5));                        // 7
    prog.push_back(w(OP_STOP));                              // 8
    prog.push_back(w(OP_ENTER, 0, 4));                       // 9: f
    prog.push_back(w(OP_LOADI8, 2, 42));                     // 10
    prog.push_back(w(OP_SSEND, 1, 21, 1));                   // 11: __raise(42)
    prog.push_back(w(OP_RETNIL));                            // 12
    while (prog.size() < 200) prog.push_back(w(OP_NOP));
    prog.push_back(w_catch(1'b0, 3, 4, 6));
    run();
    expect_halt();
    expect_reg(3, VNIL);
    expect_reg(4, vint(42));
    expect_reg(5, vint(7));
    expect_val("exc", dut.core.exc, VNIL);

    begin_test("uncaught raise is an error");
    method_entry(CLS_NIL, 21, tgt_prim(PR_RAISE));
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_HTABLE, 0, 200, 1));                 // 1
    prog.push_back(w(OP_LOADI_1, 2));                        // 2
    prog.push_back(w(OP_SSEND, 1, 21, 1));                   // 3: 覆う handler が無い
    prog.push_back(w(OP_STOP));                              // 4
    while (prog.size() < 200) prog.push_back(w(OP_NOP));
    prog.push_back(w_catch(1'b0, 4, 5, 4));
    run();
    expect_error(3);

    begin_test("return through ensure");
    method_entry(CLS_NIL, 20, 16'd4);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_HTABLE, 0, 200, 1));                 // 1
    prog.push_back(w(OP_SSEND0, 1, 20));                     // 2: R1 = g
    prog.push_back(w(OP_STOP));                              // 3
    prog.push_back(w(OP_ENTER, 0, 4));                       // 4: g
    prog.push_back(w(OP_LOADI_3, 1));                        // 5
    prog.push_back(w(OP_RETURN, 1));                         // 6: ensure [6, 7) -> 7
    prog.push_back(w(OP_EXCEPT, 2));                         // 7: R2 = 巻き戻しの塊
    prog.push_back(w(OP_LOADI_6, 3));                        // 8: ensure の本体
    prog.push_back(w(OP_RAISEIF, 2));                        // 9: return の続き
    prog.push_back(w(OP_STOP));                              // 10
    while (prog.size() < 200) prog.push_back(w(OP_NOP));
    prog.push_back(w_catch(1'b1, 6, 7, 7));
    run();
    expect_halt();
    expect_reg(1, vint(3));
    expect_reg(4, vint(6));
    expect_val("exc", dut.core.exc, VNIL);

    begin_test("JMPUW through ensure");
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_HTABLE, 0, 200, 1));                 // 1
    prog.push_back(w(OP_LOADI_0, 1));                        // 2
    prog.push_back(w(OP_LOADI_1, 2));                        // 3
    prog.push_back(w(OP_JMPUW, 0, 9));                       // 4: ensure [3, 5) -> 6、行き先は外
    prog.push_back(w(OP_STOP));                              // 5
    prog.push_back(w(OP_EXCEPT, 3));                         // 6
    prog.push_back(w(OP_LOADI_4, 4));                        // 7
    prog.push_back(w(OP_RAISEIF, 3));                        // 8: 9 へ
    prog.push_back(w(OP_LOADI_5, 5));                        // 9
    prog.push_back(w(OP_STOP));                              // 10
    while (prog.size() < 200) prog.push_back(w(OP_NOP));
    prog.push_back(w_catch(1'b1, 3, 5, 6));
    run();
    expect_halt();
    expect_reg(4, vint(4));
    expect_reg(5, vint(5));
    if (dut.core.regs[3][VAL_BITS-1 -: TAG_BITS] != TAG_OBJ || dut.core.heap[dut.core.regs[3][10:0]][31:16] != CLS_BRK)
      $fatal(1, "%s: R3 is not a break object", name);

    begin_test("break through ensure in an iterator");
    method_entry(CLS_NIL, 20, 16'd5);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_HTABLE, 0, 200, 1));                 // 1
    prog.push_back(w(OP_BLOCK, 2, 12));                      // 2
    prog.push_back(w(OP_SSEND, 1, 20, 16'h80));              // 3: R1 = each { break 99 }
    prog.push_back(w(OP_STOP));                              // 4
    prog.push_back(w(OP_ENTER, 0, 5));                       // 5: each
    prog.push_back(w(OP_MOVE, 3, 1));                        // 6
    prog.push_back(w(OP_BLKCALL, 3, 0));                     // 7: ensure [7, 8) -> 8
    prog.push_back(w(OP_EXCEPT, 2));                         // 8
    prog.push_back(w(OP_LOADI_7, 4));                        // 9
    prog.push_back(w(OP_RAISEIF, 2));                        // 10
    prog.push_back(w(OP_RETNIL));                            // 11
    prog.push_back(w(OP_ENTER, 0, 3));                       // 12: ブロック
    prog.push_back(w(OP_LOADI8, 1, 99));                     // 13
    prog.push_back(w(OP_BREAK, 1, 0, 1));                    // 14
    while (prog.size() < 200) prog.push_back(w(OP_NOP));
    prog.push_back(w_catch(1'b1, 7, 8, 8));
    run();
    expect_halt();
    expect_reg(1, vint(99));
    expect_reg(5, vint(7));

    begin_test("rescue compares classes");
    method_entry(ISA_BIT | CLS_INT, CLS_INT, 16'd1);
    prog.push_back(w_table());                               // 0
    prog.push_back(w(OP_LOADI_5, 1));                        // 1
    prog.push_back(w(OP_CLASS, 2, CLS_INT));                 // 2
    prog.push_back(w(OP_RESCUE, 1, 2));                      // 3: R2 = true
    prog.push_back(w(OP_CLASS, 3, CLS_ARRAY));               // 4
    prog.push_back(w(OP_RESCUE, 1, 3));                      // 5: R3 = false
    prog.push_back(w(OP_LOADI_1, 4));                        // 6
    prog.push_back(w(OP_RESCUE, 1, 4));                      // 7: クラスでない
    run();
    expect_error(7);
    expect_reg(2, VTRUE);
    expect_reg(3, VFALSE);

    $display("%0d cases ok", npass);
    $display("PASS mrb_core_tb");
    $finish;
  end
endmodule
