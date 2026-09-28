// mruby のバイトコード (.mrb、RITE0400) を ROM から直接読んで実行する CPU (issue #4、反復 R2)。
// 範囲は Lチカ (fpga/rite/blink.rb、loop 版) と、それが呼ぶ mruby の mrblib (kernel.rb の Kernel#loop) に出る命令と
// メソッドだけ。範囲の外の命令やメソッドに当たると error を立てて止まる (黙って違うことをしない)。
//
// ROM: .mrb を並べたもの (rake fpga:rite:hex が kernel.rb と blink.rb を mrbc して作る)。mruby の mrb_open が mrblib を
// 読んでから app を読むのと同じく、先頭の .mrb から 1 つずつ、読んで (load.c の read_irep) 実行する。
// 見出しの最初のバイトが 0 なら、もう .mrb は無いので止まる (halted)。
//
// - 命令 (include/mruby/ops.h の番号と operand の形): NOP MOVE LOADI8 LOADINEG LOADI__1〜LOADI_7 LOADI16 LOADSYM
//   LOADNIL LOADSELF GETCONST GETMCNST GETUPVAR JMP JMPIF JMPNOT SSEND SSENDB SEND BLKCALL ENTER RETURN RETNIL
//   BLKPUSH BLOCK MODULE EXEC TDEF STOP
// - メソッドの探索 (class.c の mrb_method_search_vm): 受け手のクラスの祖先の並びを順に、メソッド表 (クラス、sym) を引く。
//   メソッド表は、C の関数 (gem の init の mrb_define_method に当たる 4 行) と、実行した TDEF と module_function が足す行。
//   C の関数: GPIO.new (initialize の _init と set_dir に当たる所だけ。gpio.rb は通らない)、GPIO#write (gpio.c mrb_write)、
//   Kernel#sleep_ms (mruby-task task.c mrb_f_sleep_ms)、Module#module_function (class.c mrb_mod_module_function の引数ありの形)
// - 呼び出し: vm.c の cipush / OP_RETURN の形。呼ばれた側の R0 は呼んだ側の R[a] (レジスタの窓)。枠は 4 段
// - 値: nil、Integer (32bit。mruby の 64bit でない)、Symbol (組み込みの名前の番号)、クラスとモジュール (番号)、GPIO の object (pin)、
//   main、Proc (irep、env の窓の位置、target class)。レジスタは 64 本 (M9K)。env は枠が生きている間だけ (枠の外へ出た Proc は範囲外)
// - ピンの水準は host の板のモデル (firmware-patches/posix-board-gpio.patch) と同じ式: (dir & out) | (~dir & ~pull_down)、
//   pull_down は無いので入力のピンは 1
// - 時刻: MS_CYCLES の cycle ごとに ms を 1 進める。sleep_ms(n) は呼んだ時の ms + n まで待つ
//
// 実行: 1 命令を「命令のバイト → operand → レジスタを 3 本読む → (SEND はメソッドの探索) → 実行」の順に進める。
// レジスタの読みは同期 (M9K) で 1 cycle に 1 本、書きは 1 本。速さより小さく浅くする反復
`timescale 1ns / 1ps
module rite_core #(
  parameter int ROM_BYTES = 2048,
  parameter     ROM_FILE  = "",     // $readmemh の file (1 行 1 バイト)。型を付けると Icarus が渡せない
  parameter int MS_CYCLES = 50_000  // 1 ms の cycle 数 (CLOCK_50 なら 50,000)
) (
  input  logic        clk,
  input  logic        rst_n,
  output logic [31:0] pins,       // ピンの水準 (bit n = pin n)
  output logic [31:0] ms_now,     // 起動からの ms
  output logic        halted,     // 正しく終わった (最後の .mrb の RETURN / STOP)
  output logic        error,      // 範囲の外に当たって止まった
  output logic [7:0]  error_op,   // その時の命令
  output logic [15:0] error_pc    // その時の命令の番地 (ROM の中)
);
  // ---- ROM (1 cycle 遅れの同期読み出し。M9K に入る形) ----
  localparam int AW = $clog2(ROM_BYTES);
  logic [AW-1:0] rom_addr;
  logic [7:0]    rom_q;
  rite_rom #(.BYTES(ROM_BYTES), .FILE(ROM_FILE)) rom (.clk, .addr(rom_addr), .q(rom_q));

  // ---- 時計 ----
  localparam int MW = $clog2(MS_CYCLES + 1);
  logic [MW-1:0] ms_cnt;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ms_cnt <= '0;
      ms_now <= '0;
    end else if (ms_cnt == MW'(MS_CYCLES - 1)) begin
      ms_cnt <= '0;
      ms_now <= ms_now + 32'd1;
    end else begin
      ms_cnt <= ms_cnt + MW'(1);
    end

  // ---- 値とレジスタ (M9K: 同期読み 1 本、書き 1 本) ----
  localparam logic [2:0] T_NIL = 3'd0, T_INT = 3'd1, T_SYM = 3'd2, T_CLASS = 3'd3, T_GPIO = 3'd4, T_MAIN = 3'd5,
                         T_PROC = 3'd6, T_FALSE = 3'd7;
  typedef struct packed { logic [2:0] tag; logic [31:0] val; } value_t;
  localparam logic [34:0] NIL_V = 35'd0;
  localparam int NREG = 64, RW = 6;
  value_t        regs [0:NREG-1];
  logic [RW-1:0] ridx;         // 読むレジスタ。rd はその次の cycle に regs[ridx] になる
  value_t        rd;
  logic          we;           // 次の cycle に regs[widx] へ wval を書く
  logic [RW-1:0] widx;
  value_t        wval;
  always_ff @(posedge clk) begin
    if (we) regs[widx] <= wval;
    rd <= regs[ridx];
  end

  // ---- クラスとモジュール (番号) と祖先の並び ----
  localparam logic [3:0] C_NONE = 4'd0, C_BASIC = 4'd1, C_OBJECT = 4'd2, C_KERNEL = 4'd3, C_MODULE = 4'd4,
                         C_CLASS = 4'd5, C_INTEGER = 4'd6, C_NIL = 4'd7, C_SYMBOL = 4'd8, C_PROC = 4'd9,
                         C_GPIO = 4'd10, C_GPIO_S = 4'd11, C_KERNEL_S = 4'd12;
  // i 番目の祖先 (0 は自分)。class.c の mrb_init_class と kernel.c の Object への include、gem の init が作る並び。
  // メソッド表に行の無いクラス (Comparable、Numeric、Object と BasicObject の特異クラス) は省いた (探索の結果は同じ)
  function automatic logic [3:0] anc(input logic [3:0] c, input logic [2:0] i);
    logic [27:0] l;  // 先頭が下位 4bit
    case (c)
      C_OBJECT:                              l = {16'd0, C_BASIC, C_KERNEL, C_OBJECT};
      C_GPIO, C_INTEGER, C_NIL, C_SYMBOL, C_PROC: l = {12'd0, C_BASIC, C_KERNEL, C_OBJECT, c};
      C_GPIO_S:                              l = {4'd0, C_BASIC, C_KERNEL, C_OBJECT, C_MODULE, C_CLASS, C_GPIO_S};
      C_KERNEL_S:                            l = {8'd0, C_BASIC, C_KERNEL, C_OBJECT, C_MODULE, C_KERNEL_S};
      default:                               l = '0;
    endcase
    return (i == 3'd7) ? C_NONE : l[{i, 2'b00} +: 4];
  endfunction
  // 値のクラス (mrb_class)。クラスとモジュールは特異クラス
  function automatic logic [3:0] class_of(input value_t v);
    case (v.tag)
      T_NIL:   return C_NIL;
      T_INT:   return C_INTEGER;
      T_SYM:   return C_SYMBOL;
      T_CLASS: return (v.val[3:0] == C_GPIO) ? C_GPIO_S : (v.val[3:0] == C_KERNEL) ? C_KERNEL_S : C_NONE;
      T_GPIO:  return C_GPIO;
      T_MAIN:  return C_OBJECT;
      T_PROC:  return C_PROC;
      default: return C_NONE;
    endcase
  endfunction

  // ---- 組み込みの名前 (presym に当たる。sym の表の値。0 は組み込みに無い名前) ----
  localparam logic [3:0] N_NONE = 4'd0, N_GPIO = 4'd1, N_OUT = 4'd2, N_IN = 4'd3, N_NEW = 4'd4, N_WRITE = 4'd5,
                         N_SLEEP_MS = 4'd6, N_LOOP = 4'd7, N_KERNEL = 4'd8, N_MODFUNC = 4'd9;
  localparam int NB = 9;
  function automatic logic [3:0] bname_len(input logic [3:0] id);
    case (id)
      N_GPIO: return 4'd4;  N_OUT: return 4'd3;  N_IN: return 4'd2;  N_NEW: return 4'd3;  N_WRITE: return 4'd5;
      N_SLEEP_MS: return 4'd8;  N_LOOP: return 4'd4;  N_KERNEL: return 4'd6;  N_MODFUNC: return 4'd15;
      default: return 4'd0;
    endcase
  endfunction
  function automatic logic [7:0] bname_char(input logic [3:0] id, input logic [3:0] p);
    logic [127:0] s;
    case (id)
      N_GPIO:     s = "GPIO";
      N_OUT:      s = "OUT";
      N_IN:       s = "IN";
      N_NEW:      s = "new";
      N_WRITE:    s = "write";
      N_SLEEP_MS: s = "sleep_ms";
      N_LOOP:     s = "loop";
      N_KERNEL:   s = "Kernel";
      N_MODFUNC:  s = "module_function";
      default:    s = '0;
    endcase
    // 文字列の定数は右詰め: 長さ L の名前の p 文字目は s の上から
    return (p < bname_len(id)) ? s[{bname_len(id) - 4'd1 - p, 3'b000} +: 8] : 8'd0;
  endfunction

  // ---- 読んだ irep の表 (load.c の read_irep が作る mrb_irep の要る所だけ) ----
  localparam int NIREP = 8, NREPS = 8, NSYMS = 32, NPD = 4;
  logic [AW-1:0] ir_iseq  [0:NIREP-1];   // iseq の ROM の番地
  logic [5:0]    ir_nregs [0:NIREP-1];
  logic [3:0]    ir_repb  [0:NIREP-1];   // 子 irep (reps) の表の始まり
  logic [3:0]    ir_rlen  [0:NIREP-1];
  logic [5:0]    ir_symb  [0:NIREP-1];   // sym の表の始まり
  logic [5:0]    ir_nsym  [0:NIREP-1];
  logic [2:0]    reps_tab [0:NREPS-1];   // irep の番号
  logic [3:0]    sym_tab  [0:NSYMS-1];   // 組み込みの名前の番号
  logic [3:0]    ir_n, rep_n;
  logic [5:0]    sym_n;

  // ---- メソッド表 (クラス、sym → irep か C の関数)。可視性は private の印だけ ----
  localparam int NMT = 8;
  localparam logic [2:0] F_GPIO_NEW = 3'd0, F_GPIO_WRITE = 3'd1, F_SLEEP_MS = 3'd2, F_MODFUNC = 3'd3;
  logic       mt_v    [0:NMT-1];
  logic [3:0] mt_cls  [0:NMT-1];
  logic [3:0] mt_mid  [0:NMT-1];
  logic       mt_priv [0:NMT-1];
  logic       mt_irep [0:NMT-1];   // 1: irep、0: C の関数
  logic [2:0] mt_tgt  [0:NMT-1];   // irep の番号か C の関数の番号
  logic [3:0] mt_n;

  // ---- 呼び出しの枠 (mrb_callinfo の要る所だけ)。cur_* が今の枠、ci_* が積んだ枠 ----
  localparam int NCI = 4;
  logic [2:0]    cur_irep;
  logic [RW-1:0] cur_base, cur_env;   // レジスタの窓の始まり、Proc の env の窓 (ブロックの時)
  logic [3:0]    cur_tc, cur_argc;    // target class、渡された引数の数
  logic          cur_isblk;
  logic [5:0]    cur_symb, cur_nsym;  // cur_irep の表の写し (S_FRAME で読む)
  logic [3:0]    cur_repb, cur_rlen;
  logic [2:0]    ci_irep [0:NCI-1];
  logic [RW-1:0] ci_base [0:NCI-1], ci_env [0:NCI-1];
  logic [3:0]    ci_tc [0:NCI-1], ci_argc [0:NCI-1];
  logic          ci_isblk [0:NCI-1];
  logic [AW-1:0] ci_pc [0:NCI-1];
  logic [2:0]    sp;
  logic [1:0]    spm1;       // sp - 1 (積んだ一番上の枠)
  assign spm1 = 2'(sp - 3'd1);

  // ---- GPIO (host の板のモデルと同じ) ----
  localparam logic [31:0] FLAG_IN = 32'd1, FLAG_OUT = 32'd2; // picoruby-gpio/include/gpio.h
  // 書き口は 1 本: 実行が gpio_we と pin と値を置き、次の cycle に mask で書く
  logic [31:0] gpio_out, gpio_dir;
  assign pins = (gpio_dir & gpio_out) | ~gpio_dir;
  logic        gpio_we, gpio_set_dir, gpio_out_v, gpio_dir_v;
  logic [4:0]  gpio_pin;
  logic [31:0] gpio_mask;
  assign gpio_mask = 32'd1 << gpio_pin;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      gpio_out <= '0;
      gpio_dir <= '0;
    end else if (gpio_we) begin
      gpio_out <= gpio_out_v ? (gpio_out | gpio_mask) : (gpio_out & ~gpio_mask);
      if (gpio_set_dir) gpio_dir <= gpio_dir_v ? (gpio_dir | gpio_mask) : (gpio_dir & ~gpio_mask);
    end

  // ---- 命令の番号 (ops.h) ----
  localparam logic [7:0] OP_NOP = 8'd0, OP_MOVE = 8'd1, OP_LOADI8 = 8'd3, OP_LOADINEG = 8'd4, OP_LOADI16 = 8'd14,
                         OP_LOADSYM = 8'd16, OP_LOADNIL = 8'd17, OP_LOADSELF = 8'd18, OP_GETCONST = 8'd29,
                         OP_GETMCNST = 8'd31, OP_GETUPVAR = 8'd33, OP_JMP = 8'd38, OP_JMPIF = 8'd39, OP_JMPNOT = 8'd40,
                         OP_SSEND = 8'd47, OP_SSENDB = 8'd49, OP_SEND = 8'd50, OP_BLKCALL = 8'd54, OP_ENTER = 8'd57,
                         OP_RETURN = 8'd61, OP_RETNIL = 8'd64, OP_BLKPUSH = 8'd68, OP_BLOCK = 8'd98,
                         OP_MODULE = 8'd104, OP_EXEC = 8'd105, OP_TDEF = 8'd107, OP_STOP = 8'd118;

  // operand のバイト数 (ops.h の Z / B / BB / S / BS / BBB / W)。範囲の外は 7
  function automatic logic [2:0] opnd_bytes(input logic [7:0] o);
    case (o)
      OP_NOP, OP_RETNIL, OP_STOP:                                          return 3'd0;
      8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13,
      OP_LOADNIL, OP_LOADSELF, OP_RETURN:                                  return 3'd1;
      OP_MOVE, OP_LOADI8, OP_LOADINEG, OP_LOADSYM, OP_GETCONST, OP_GETMCNST, OP_JMP,
      OP_BLKCALL, OP_BLOCK, OP_MODULE, OP_EXEC:                            return 3'd2;
      OP_LOADI16, OP_GETUPVAR, OP_JMPIF, OP_JMPNOT, OP_SSEND, OP_SSENDB, OP_SEND,
      OP_ENTER, OP_BLKPUSH, OP_TDEF:                                       return 3'd3;
      default:                                                             return 3'd7;
    endcase
  endfunction

  // 見出しで確かめるバイト: "RITE0400" (0..7) と "IREP" (20..23)
  function automatic logic hdr_ok(input logic [4:0] i, input logic [7:0] b);
    case (i)
      5'd0: return b == "R";  5'd1: return b == "I";  5'd2: return b == "T";  5'd3: return b == "E";
      5'd4: return b == "0";  5'd5: return b == "4";  5'd6: return b == "0";  5'd7: return b == "0";
      5'd20: return b == "I"; 5'd21: return b == "R"; 5'd22: return b == "E"; 5'd23: return b == "P";
      default: return 1'b1;
    endcase
  endfunction

  // ---- 状態 ----
  typedef enum logic [4:0] {
    S_CLR, S_HDR, S_REC, S_SKIP, S_CATCH, S_PLEN, S_PTT, S_PSTR, S_SLEN, S_SYMLEN, S_SYMCHR, S_SYMNUL, S_IDONE, S_UP,
    S_OP, S_OPND, S_RD0, S_RD1, S_RD2, S_RD3, S_LOOK, S_EXEC, S_CALL, S_PRS0, S_PRS1, S_PRS2, S_PWS, S_PWN,
    S_FRAME, S_SLEEP, S_HALT, S_ERR
  } state_t;
  state_t        st;
  logic          rd_wait;   // rom_addr を出した次の cycle (rom_q がまだ古い)
  logic [AW-1:0] ptr, fbase, fnext;
  logic [4:0]    hdr_i;
  logic [23:0]   acc;       // 見出しの数や operand を集める
  logic [2:0]    cnt;       // 集めたバイト数
  logic [15:0]   rec_nregs, rec_rlen, rec_clen, pool_left, nsyms, sym_len;
  logic [AW-1:0] skip_base, skip;     // S_SKIP: ptr = skip_base + skip (1 cycle に加算 1 つ)
  state_t        skip_next;
  logic [2:0]    pi, file_top;         // 読んでいる irep、今の .mrb の一番上の irep
  logic [3:0]    pslot [0:NPD-1];      // 読みの stack: 親の reps の次に埋める所と、残りの子の数
  logic [3:0]    prem  [0:NPD-1];
  logic [2:0]    pd;
  logic [1:0]    pdm1;       // pd - 1 (stack の一番上)
  assign pdm1 = 2'(pd - 3'd1);
  logic [5:0]    sym_i;
  logic [3:0]    chr_i;
  logic [NB:1]   match;
  logic [7:0]    op, a_q;
  logic [2:0]    nopnd;
  logic [AW-1:0] op_pc;
  logic [31:0]   wake_ms;
  value_t        v0, v1;     // 読んだレジスタ: (MOVE は b、SSEND は self、…) と a+1。a+2 は S_EXEC の rd
  logic [3:0]    bsym;       // b の sym の組み込みの名前 (S_RD0 で読む)
  logic [2:0]    lk_i;       // メソッドの探索: 祖先の何番目か
  logic [3:0]    lk_cls, lk_owner;
  logic          lk_priv, lk_irep;
  logic [2:0]    lk_tgt;
  // 呼び出しの準備 (S_EXEC が置き、S_CALL が枠を積む)
  logic [2:0]    c_irep;
  logic [6:0]    c_base;
  logic [RW-1:0] c_env;
  logic [3:0]    c_tc, c_argc;
  logic          c_isblk, c_nil;
  logic [1:0]    c_self;     // 0: そのまま、1: cself を R0 に書く、2: env の R0 を読んで R0 に書く (ブロックの self)
  logic [4:0]    c_clr;      // 窓のここから nregs までを nil で埋める (stack_clear)
  value_t        cself;
  logic [6:0]    clr_i, clr_end;
  logic          clr_boot;
  logic [RW-1:0] nil_idx;

  // operand: 最初のバイトは a_q、残りは acc に詰める。B: a / BB: a b / S: {a_q, acc} / BS: a S / BBB: a b c / W: {a_q, acc}
  logic [7:0] ob, oc;
  assign ob = (nopnd == 3'd3) ? acc[15:8] : acc[7:0];
  assign oc = acc[7:0];
  logic [6:0] abs_a;        // R[a] の窓の外の番号
  assign abs_a = 7'(cur_base) + 7'(a_q[4:0]);
  logic [3:0] n_args;       // SEND の引数の数 (c = n | kw<<4)
  assign n_args = oc[3:0];
  logic [5:0] blk_off;      // BLKPUSH: m1+r+m2+kd (16=m5:r1:m5:d1:lv4)
  assign blk_off = 6'(acc[15:11]) + 6'(acc[10]) + 6'(acc[9:5]) + 6'(acc[4]);

  // 実行の前に確かめること: sym と子 irep の番号が表の中、レジスタが窓の中、範囲の外の operand
  logic uses_sym, is_send, regop, bad_opnd;
  assign uses_sym = (op == OP_GETCONST || op == OP_GETMCNST || op == OP_SSEND || op == OP_SSENDB || op == OP_SEND ||
                     op == OP_LOADSYM || op == OP_MODULE || op == OP_TDEF);
  assign is_send  = (op == OP_SSEND || op == OP_SSENDB || op == OP_SEND);
  assign regop    = (nopnd != 3'd0 && op != OP_JMP && op != OP_ENTER);
  assign bad_opnd = (regop && (a_q[7:5] != 3'd0 || abs_a[6])) ||
                    (uses_sym && ob >= 8'(cur_nsym)) ||
                    (op == OP_MOVE && (ob[7:5] != 3'd0 || 7'(cur_base) + 7'(ob[4:0]) > 7'd63)) ||
                    (is_send && (oc[7:4] != 4'd0 || n_args == 4'd15 || abs_a + 7'(n_args) + 7'd1 > 7'd63)) ||
                    (op == OP_GETUPVAR && (oc != 8'd0 || !cur_isblk || ob[7:5] != 3'd0 ||
                                           7'(cur_env) + 7'(ob[4:0]) > 7'd63)) ||
                    (op == OP_BLKPUSH && (acc[3:0] != 4'd0 || 7'(cur_base) + 7'(blk_off) + 7'd1 > 7'd63)) ||
                    (op == OP_BLKCALL && (ob[7:4] != 4'd0 || abs_a + 7'(ob[3:0]) > 7'd63)) ||
                    ((op == OP_EXEC || op == OP_BLOCK) && ob >= 8'(cur_rlen)) ||
                    (op == OP_TDEF && oc >= 8'(cur_rlen));

  // メソッド表を (クラス、名前) で引く (全行を並べて比べる)。同じ組の行は 1 つだけ (定義は置き換える)。8 は無い
  logic [3:0] lk_hit, def_hit, mf_src, mf_dst;
  always_comb begin
    lk_hit = 4'd8; def_hit = 4'd8; mf_src = 4'd8; mf_dst = 4'd8;
    for (int j = 0; j < NMT; j++) begin
      if (mt_v[j] && mt_cls[j] == anc(lk_cls, lk_i) && mt_mid[j] == bsym) lk_hit = 4'(j);
      if (mt_v[j] && mt_cls[j] == cur_tc && mt_mid[j] == bsym) def_hit = 4'(j);
      if (mt_v[j] && mt_cls[j] == C_KERNEL && mt_mid[j] == v1.val[3:0]) mf_src = 4'(j);
      if (mt_v[j] && mt_cls[j] == C_KERNEL_S && mt_mid[j] == v1.val[3:0]) mf_dst = 4'(j);
    end
  end

  // 命令を実行する cycle (テストベンチの +TRACE が見る。回路の中では使わない)
  /* verilator lint_off UNUSEDSIGNAL */
  logic in_exec;
  assign in_exec = (st == S_EXEC) && !rd_wait;
  /* verilator lint_on UNUSEDSIGNAL */
  logic truthy;
  assign truthy = (v0.tag != T_NIL && v0.tag != T_FALSE);

`define RITE_ERR begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
`define RITE_PERR begin st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr); end
`define RITE_NEXT(p) begin ptr <= (p); rom_addr <= (p); rd_wait <= 1'b1; end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_CLR; clr_boot <= 1'b1; clr_i <= '0; clr_end <= 7'd64;
      rd_wait <= 1'b1; ptr <= '0; rom_addr <= '0; fbase <= '0; fnext <= '0; hdr_i <= '0;
      acc <= '0; cnt <= '0; skip_base <= '0; skip <= '0; skip_next <= S_CLR; rec_nregs <= '0; rec_rlen <= '0; rec_clen <= '0; pool_left <= '0; nsyms <= '0;
      sym_len <= '0; pi <= '0; file_top <= '0; pd <= '0; sym_i <= '0; chr_i <= '0; match <= '0;
      op <= '0; a_q <= '0; nopnd <= '0; op_pc <= '0; wake_ms <= '0; bsym <= '0;
      lk_i <= '0; lk_cls <= '0; lk_owner <= '0; lk_priv <= 1'b0; lk_irep <= 1'b0; lk_tgt <= '0;
      c_irep <= '0; c_base <= '0; c_env <= '0; c_tc <= '0; c_argc <= '0; c_isblk <= 1'b0; c_nil <= 1'b0;
      c_self <= '0; c_clr <= '0; cself <= NIL_V; nil_idx <= '0;
      ridx <= '0; we <= 1'b0; widx <= '0; wval <= NIL_V; v0 <= NIL_V; v1 <= NIL_V;
      gpio_we <= 1'b0; gpio_set_dir <= 1'b0; gpio_out_v <= 1'b0; gpio_dir_v <= 1'b0; gpio_pin <= '0;
      halted <= 1'b0; error <= 1'b0; error_op <= '0; error_pc <= '0;
      ir_n <= '0; rep_n <= '0; sym_n <= '0; sp <= '0;
      cur_irep <= '0; cur_base <= '0; cur_env <= '0; cur_tc <= C_OBJECT; cur_argc <= '0; cur_isblk <= 1'b0;
      cur_symb <= '0; cur_nsym <= '0; cur_repb <= '0; cur_rlen <= '0;
      for (int i = 0; i < NIREP; i++) begin
        ir_iseq[i] <= '0; ir_nregs[i] <= '0; ir_repb[i] <= '0; ir_rlen[i] <= '0; ir_symb[i] <= '0; ir_nsym[i] <= '0;
      end
      for (int i = 0; i < NREPS; i++) reps_tab[i] <= '0;
      for (int i = 0; i < NSYMS; i++) sym_tab[i] <= N_NONE;
      for (int i = 0; i < NPD; i++) begin pslot[i] <= '0; prem[i] <= '0; end
      for (int i = 0; i < NCI; i++) begin
        ci_irep[i] <= '0; ci_base[i] <= '0; ci_env[i] <= '0; ci_tc[i] <= '0; ci_argc[i] <= '0;
        ci_isblk[i] <= 1'b0; ci_pc[i] <= '0;
      end
      // C の関数 (gem と core の init の mrb_define_method)
      for (int i = 0; i < NMT; i++) begin
        mt_v[i] <= 1'b0; mt_cls[i] <= '0; mt_mid[i] <= '0; mt_priv[i] <= 1'b0; mt_irep[i] <= 1'b0; mt_tgt[i] <= '0;
      end
      mt_v[0] <= 1'b1; mt_cls[0] <= C_GPIO_S;   mt_mid[0] <= N_NEW;      mt_tgt[0] <= F_GPIO_NEW;
      mt_v[1] <= 1'b1; mt_cls[1] <= C_GPIO;     mt_mid[1] <= N_WRITE;    mt_tgt[1] <= F_GPIO_WRITE;
      mt_v[2] <= 1'b1; mt_cls[2] <= C_KERNEL;   mt_mid[2] <= N_SLEEP_MS; mt_tgt[2] <= F_SLEEP_MS;
      mt_v[3] <= 1'b1; mt_cls[3] <= C_MODULE;   mt_mid[3] <= N_MODFUNC;  mt_tgt[3] <= F_MODFUNC;
      mt_n <= 4'd4;
    end else begin
      we <= 1'b0;
      gpio_we <= 1'b0;
      if (rd_wait) begin
        rd_wait <= 1'b0;   // rom_q は次の cycle に rom[rom_addr] になる
      end else begin
        case (st)
          // レジスタを clr_i から clr_end の前まで nil にする (起動と、呼び出しの stack_clear)
          S_CLR: begin
            if (clr_i >= clr_end) st <= clr_boot ? S_HDR : S_FRAME;
            else begin we <= 1'b1; widx <= clr_i[RW-1:0]; wval <= NIL_V; clr_i <= clr_i + 7'd1; end
          end

          // ---- .mrb を読む (load.c の read_irep) ----
          // 見出し 0..23: "RITE0400"、size (8..11)、"IREP"。最初のバイトが 0 なら、もう .mrb は無い
          S_HDR: begin
            if (hdr_i == 5'd0 && rom_q == 8'd0) st <= S_HALT;
            else if (!hdr_ok(hdr_i, rom_q)) `RITE_PERR
            else begin
              acc <= {acc[15:0], rom_q};
              if (hdr_i == 5'd11) begin
                if (acc[23:8] != 16'd0 || {acc[7:0], rom_q} >= 16'(ROM_BYTES)) `RITE_PERR
                else fnext <= fbase + AW'({acc[7:0], rom_q});
              end
              if (hdr_i == 5'd23) begin hdr_i <= '0; acc <= '0; pd <= '0; `RITE_NEXT(fbase + AW'(32)) st <= S_REC; end
              else begin hdr_i <= hdr_i + 5'd1; `RITE_NEXT(ptr + AW'(1)) end
            end
          end
          // irep の record の 16 バイト: size(4) nlocals(2) nregs(2) rlen(2) clen(2) ilen(4)
          S_REC: begin
            acc <= {acc[15:0], rom_q};
            if (hdr_i == 5'd7)  rec_nregs <= {acc[7:0], rom_q};
            if (hdr_i == 5'd9)  rec_rlen  <= {acc[7:0], rom_q};
            if (hdr_i == 5'd11) rec_clen  <= {acc[7:0], rom_q};
            if (hdr_i == 5'd15) begin
              if (acc[23:8] != 16'd0 || ir_n == 4'(NIREP) || rec_nregs == 16'd0 || rec_nregs > 16'd32 ||
                  16'(rep_n) + rec_rlen > 16'(NREPS) || (pd != 3'd0 && prem[pdm1] == 4'd0)) `RITE_PERR
              else begin
                ir_iseq[ir_n[2:0]] <= ptr + AW'(1);
                ir_nregs[ir_n[2:0]] <= rec_nregs[5:0];
                ir_repb[ir_n[2:0]] <= rep_n;
                ir_rlen[ir_n[2:0]] <= rec_rlen[3:0];
                rep_n <= rep_n + rec_rlen[3:0];
                pi <= ir_n[2:0];
                ir_n <= ir_n + 4'd1;
                if (pd == 3'd0) file_top <= ir_n[2:0];
                else begin
                  reps_tab[pslot[pdm1][2:0]] <= ir_n[2:0];
                  pslot[pdm1] <= pslot[pdm1] + 4'd1;
                  prem[pdm1] <= prem[pdm1] - 4'd1;
                end
                // iseq を飛ばし (S_SKIP)、catch handler (13 バイトずつ) を飛ばす (S_CATCH)
                skip_base <= ptr + AW'(1); skip <= AW'({acc[7:0], rom_q}); skip_next <= S_CATCH;
                cnt <= '0; acc <= '0; st <= S_SKIP;
              end
            end else begin
              hdr_i <= hdr_i + 5'd1; `RITE_NEXT(ptr + AW'(1))
            end
          end
          // 飛ばした先が ROM の外なら範囲の外
          S_SKIP: begin
            if ({1'b0, skip_base} + {1'b0, skip} >= (AW+1)'(ROM_BYTES)) `RITE_PERR
            else begin `RITE_NEXT(skip_base + skip) st <= skip_next; end
          end
          S_CATCH: begin
            if (rec_clen == 16'd0) st <= S_PLEN;
            else begin rec_clen <= rec_clen - 16'd1; `RITE_NEXT(ptr + AW'(13)) end
          end
          // pool の数
          S_PLEN: begin
            acc <= {acc[15:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt == 3'd1) begin
              pool_left <= {acc[7:0], rom_q}; cnt <= '0; acc <= '0;
              st <= ({acc[7:0], rom_q} == 16'd0) ? S_SLEN : S_PTT;
            end else cnt <= cnt + 3'd1;
          end
          // pool の 1 つ: 種類で長さが決まる (load.c の read_irep_record_1)。文字列の中身は使わないので飛ばす
          S_PTT: begin
            case (rom_q)
              8'd0, 8'd2: begin `RITE_NEXT(ptr + AW'(1)) cnt <= '0; acc <= '0; st <= S_PSTR; end   // STR / SSTR
              8'd1: begin                                                                             // INT32
                `RITE_NEXT(ptr + AW'(5)) pool_left <= pool_left - 16'd1;
                st <= (pool_left == 16'd1) ? S_SLEN : S_PTT;
              end
              8'd3, 8'd5: begin                                                                       // INT64 / FLOAT
                `RITE_NEXT(ptr + AW'(9)) pool_left <= pool_left - 16'd1;
                st <= (pool_left == 16'd1) ? S_SLEN : S_PTT;
              end
              default: `RITE_PERR
            endcase
          end
          // 文字列の長さ (2 バイト)、中身、NUL
          S_PSTR: begin
            acc <= {acc[15:0], rom_q};
            if (cnt == 3'd1) begin
              skip_base <= ptr + AW'(2); skip <= AW'({acc[7:0], rom_q}); st <= S_SKIP;
              skip_next <= (pool_left == 16'd1) ? S_SLEN : S_PTT;
              pool_left <= pool_left - 16'd1; cnt <= '0; acc <= '0;
            end else begin
              cnt <= cnt + 3'd1; `RITE_NEXT(ptr + AW'(1))
            end
          end
          // sym の数
          S_SLEN: begin
            acc <= {acc[15:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt == 3'd1) begin
              nsyms <= {acc[7:0], rom_q}; sym_i <= '0; cnt <= '0; acc <= '0;
              ir_symb[pi] <= sym_n; ir_nsym[pi] <= 6'({acc[7:0], rom_q});
              if ({acc[7:0], rom_q} > 16'(NSYMS) - 16'(sym_n)) `RITE_PERR   // 残りの sym の表に入らない
              else st <= ({acc[7:0], rom_q} == 16'd0) ? S_IDONE : S_SYMLEN;
            end else cnt <= cnt + 3'd1;
          end
          // 1 つの sym: 長さ (2 バイト、0xFFFF は名前の無い sym)、名前、NUL
          S_SYMLEN: begin
            acc <= {acc[15:0], rom_q};
            if (cnt == 3'd1) begin
              sym_len <= {acc[7:0], rom_q}; chr_i <= '0; match <= '1; cnt <= '0; acc <= '0;
              if ({acc[7:0], rom_q} == 16'hFFFF) begin   // 名前の無い sym (長さだけで NUL も無い)
                sym_tab[5'(sym_n + sym_i)] <= N_NONE;
                `RITE_NEXT(ptr + AW'(1))
                if (16'(sym_i) + 16'd1 == nsyms) begin sym_n <= sym_n + 6'(nsyms); st <= S_IDONE; end
                else sym_i <= sym_i + 6'd1;
              end else begin
                st <= ({acc[7:0], rom_q} == 16'd0) ? S_SYMNUL : S_SYMCHR;
                `RITE_NEXT(ptr + AW'(1))
              end
            end else begin
              cnt <= cnt + 3'd1; `RITE_NEXT(ptr + AW'(1))
            end
          end
          // 名前を 1 文字ずつ組み込みの名前と照らす。16 文字を超える名前は組み込みに無いので読み飛ばす
          S_SYMCHR: begin
            for (int k = 1; k <= NB; k++)
              if (chr_i >= bname_len(4'(k)) || rom_q != bname_char(4'(k), chr_i)) match[k] <= 1'b0;
            if (16'(chr_i) + 16'd1 == sym_len) begin
              st <= S_SYMNUL; `RITE_NEXT(ptr + AW'(1))
            end else if (chr_i == 4'd15) begin
              match <= '0; skip_base <= ptr; skip <= AW'(sym_len - 16'd15); skip_next <= S_SYMNUL; st <= S_SKIP;
            end else begin
              `RITE_NEXT(ptr + AW'(1))
            end
            chr_i <= chr_i + 4'd1;
          end
          // NUL を読み、表に入れる (長さも一致したものだけ)
          S_SYMNUL: begin
            sym_tab[5'(sym_n + sym_i)] <= N_NONE;
            for (int k = 1; k <= NB; k++)
              if (match[k] && 16'(bname_len(4'(k))) == sym_len) sym_tab[5'(sym_n + sym_i)] <= 4'(k);
            `RITE_NEXT(ptr + AW'(1))
            if (16'(sym_i) + 16'd1 == nsyms) begin sym_n <= sym_n + 6'(nsyms); st <= S_IDONE; end
            else begin sym_i <= sym_i + 6'd1; st <= S_SYMLEN; end
          end
          // 1 つの irep を読み終えた: 子があれば読みの stack に積んで子へ
          S_IDONE: begin
            if (rec_rlen != 16'd0) begin
              if (pd == 3'(NPD)) `RITE_PERR
              else begin
                pslot[pd[1:0]] <= ir_repb[pi]; prem[pd[1:0]] <= rec_rlen[3:0]; pd <= pd + 3'd1;
                hdr_i <= '0; acc <= '0; st <= S_REC;
              end
            end else st <= S_UP;
          end
          // 子を読み終えた親を stack から降ろす。空になったら .mrb の一番上の irep を実行する
          S_UP: begin
            if (pd == 3'd0) begin
              sp <= '0; cur_irep <= file_top; cur_base <= '0; cur_env <= '0; cur_tc <= C_OBJECT; cur_argc <= '0;
              cur_isblk <= 1'b0;
              `RITE_NEXT(ir_iseq[file_top])
              cself <= {T_MAIN, 32'd0}; c_nil <= 1'b0; clr_boot <= 1'b0;
              clr_i <= 7'd1; clr_end <= 7'(ir_nregs[file_top]);
              st <= S_PWS;
            end else if (prem[pdm1] == 4'd0) pd <= pd - 3'd1;
            else begin hdr_i <= '0; acc <= '0; st <= S_REC; end
          end

          // ---- 実行 ----
          S_OP: begin
            op <= rom_q; op_pc <= ptr; nopnd <= opnd_bytes(rom_q); cnt <= '0; acc <= '0; a_q <= '0;
            `RITE_NEXT(ptr + AW'(1))
            if (opnd_bytes(rom_q) == 3'd7) begin
              st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr);
            end else if (opnd_bytes(rom_q) == 3'd0) st <= S_RD0;
            else st <= S_OPND;
          end
          S_OPND: begin
            if (cnt == 3'd0) a_q <= rom_q; else acc <= {acc[15:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt + 3'd1 == nopnd) st <= S_RD0;
            cnt <= cnt + 3'd1;
          end
          // レジスタを読む: MOVE は b、SSEND と LOADSELF は self (R0)、GETUPVAR は env の b、BLKPUSH はブロックの引数、
          // ほかは a。続けて a+1、a+2 (読みは 1 cycle 遅れ)
          S_RD0: begin
            bsym <= sym_tab[5'(cur_symb + 6'(ob))];
            if (bad_opnd) `RITE_ERR
            else begin
              case (op)
                OP_MOVE:                           ridx <= cur_base + RW'(ob);
                OP_SSEND, OP_SSENDB, OP_LOADSELF:  ridx <= cur_base;
                OP_GETUPVAR:                       ridx <= cur_env + RW'(ob);
                OP_BLKPUSH:                        ridx <= cur_base + RW'(blk_off) + RW'(1);
                default:                           ridx <= abs_a[RW-1:0];
              endcase
              st <= S_RD1;
            end
          end
          S_RD1: begin ridx <= abs_a[RW-1:0] + RW'(1); st <= S_RD2; end
          S_RD2: begin v0 <= rd; ridx <= abs_a[RW-1:0] + RW'(2); st <= S_RD3; end
          S_RD3: begin
            v1 <= rd; lk_cls <= class_of(v0); lk_i <= '0;
            st <= is_send ? S_LOOK : S_EXEC;
          end
          // メソッドの探索: 受け手のクラスの祖先を順に、メソッド表を引く。無ければ範囲の外 (method_missing は無い)
          S_LOOK: begin
            if (anc(lk_cls, lk_i) == C_NONE || bsym == N_NONE) `RITE_ERR
            else if (lk_hit != 4'd8) begin
              lk_owner <= anc(lk_cls, lk_i); lk_priv <= mt_priv[lk_hit[2:0]]; lk_irep <= mt_irep[lk_hit[2:0]];
              lk_tgt <= mt_tgt[lk_hit[2:0]]; st <= S_EXEC;
            end else lk_i <= lk_i + 3'd1;
          end
          S_EXEC: begin
            st <= S_OP;   // 次の命令は ptr から。rom_addr は ptr を指したまま
            widx <= abs_a[RW-1:0];
            case (op)
              OP_NOP: ;
              OP_MOVE, OP_LOADSELF, OP_GETUPVAR: begin we <= 1'b1; wval <= v0; end
              OP_LOADI8:   begin we <= 1'b1; wval <= {T_INT, {24'd0, ob}}; end
              OP_LOADINEG: begin we <= 1'b1; wval <= {T_INT, -{24'd0, ob}}; end
              8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13:                  // LOADI__1..LOADI_7
                begin we <= 1'b1; wval <= {T_INT, 32'(op) - 32'd6}; end
              OP_LOADI16:  begin we <= 1'b1; wval <= {T_INT, {{16{acc[15]}}, acc[15:0]}}; end
              OP_LOADSYM:  begin we <= 1'b1; wval <= {T_SYM, 28'd0, bsym}; end
              OP_LOADNIL:  begin we <= 1'b1; wval <= NIL_V; end
              OP_GETCONST: begin                                                         // Object の定数だけ
                if (bsym == N_GPIO) begin we <= 1'b1; wval <= {T_CLASS, 28'd0, C_GPIO}; end
                else if (bsym == N_KERNEL) begin we <= 1'b1; wval <= {T_CLASS, 28'd0, C_KERNEL}; end
                else `RITE_ERR
              end
              OP_GETMCNST: begin                                                         // R[a]::Syms[b]
                if (v0.tag == T_CLASS && v0.val[3:0] == C_GPIO && bsym == N_OUT) begin we <= 1'b1; wval <= {T_INT, FLAG_OUT}; end
                else if (v0.tag == T_CLASS && v0.val[3:0] == C_GPIO && bsym == N_IN) begin we <= 1'b1; wval <= {T_INT, FLAG_IN}; end
                else `RITE_ERR
              end
              OP_JMP: `RITE_NEXT(ptr + AW'({a_q, acc[7:0]}))
              OP_JMPIF:  if (truthy)  `RITE_NEXT(ptr + AW'(acc[15:0]))
              OP_JMPNOT: if (!truthy) `RITE_NEXT(ptr + AW'(acc[15:0]))
              // vm_op_blkpush: lv 0 の枠のブロックの引数。nil なら LocalJumpError (範囲の外)
              OP_BLKPUSH: if (v0.tag == T_NIL) `RITE_ERR else begin we <= 1'b1; wval <= v0; end
              // Proc: irep、env (今の窓)、target class
              OP_BLOCK: begin
                we <= 1'b1;
                wval <= {T_PROC, 12'd0, cur_tc, 2'd0, cur_base, 5'd0, reps_tab[3'(cur_repb + 4'(ob))]};
              end
              // mrb_vm_define_module: 基が nil (cref は Object) で Kernel だけ (Kernel は起動の時からある)
              OP_MODULE: if (v0.tag == T_NIL && bsym == N_KERNEL) begin we <= 1'b1; wval <= {T_CLASS, 28'd0, C_KERNEL}; end
                         else `RITE_ERR
              // 引数の形は必須の引数とブロックだけ。数は渡された数と同じだけ (ブロックの数の合わせは範囲の外)
              OP_ENTER: if (({a_q, acc[15:0]} & 24'h03FFFE) != 24'd0) `RITE_ERR
                        else if (4'({a_q[6:2]}) != cur_argc || a_q[7]) `RITE_ERR
              // vm_define_method: target class に置く (同じ名前は置き換える)。R[a] = 名前
              OP_TDEF: begin
                if (cur_tc == C_NONE || (def_hit == 4'd8 && mt_n == 4'(NMT))) `RITE_ERR
                else begin
                  mt_v[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= 1'b1;
                  mt_cls[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= cur_tc;
                  mt_mid[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= bsym;
                  mt_priv[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= 1'b0;
                  mt_irep[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= 1'b1;
                  mt_tgt[(def_hit == 4'd8) ? mt_n[2:0] : def_hit[2:0]] <= reps_tab[3'(cur_repb + 4'(oc))];
                  if (def_hit == 4'd8) mt_n <= mt_n + 4'd1;
                  we <= 1'b1; wval <= {T_SYM, 28'd0, bsym};
                end
              end
              // blockexec: R[a] (クラスかモジュール) を self と target class にして子 irep を呼ぶ
              OP_EXEC: begin
                if (v0.tag != T_CLASS) `RITE_ERR
                else begin
                  c_irep <= reps_tab[3'(cur_repb + 4'(ob))]; c_base <= abs_a; c_tc <= v0.val[3:0]; c_env <= '0;
                  c_isblk <= 1'b0; c_argc <= '0; c_self <= 2'd0; c_nil <= 1'b0; c_clr <= 5'd1; st <= S_CALL;
                end
              end
              // R[a].call(R[a+1]..R[a+b]): self は env の R0
              OP_BLKCALL: begin
                if (v0.tag != T_PROC) `RITE_ERR
                else begin
                  c_irep <= v0.val[2:0]; c_base <= abs_a; c_tc <= v0.val[19:16]; c_env <= v0.val[13:8];
                  c_isblk <= 1'b1; c_argc <= ob[3:0]; c_self <= 2'd2; c_nil <= 1'b0; c_clr <= 5'(ob[3:0]) + 5'd1;
                  st <= S_CALL;
                end
              end
              OP_SEND, OP_SSEND, OP_SSENDB: begin
                if (op == OP_SEND && lk_priv) `RITE_ERR       // private を受け手付きで呼んだ (NoMethodError)
                else if (lk_irep) begin
                  // SSEND は R[a] を self にする。ブロックの無い SEND は R[a+n+1] を nil にする
                  c_irep <= lk_tgt; c_base <= abs_a; c_tc <= lk_owner; c_env <= '0; c_isblk <= 1'b0; c_argc <= n_args;
                  c_self <= (op == OP_SEND) ? 2'd0 : 2'd1; cself <= v0; c_nil <= (op != OP_SSENDB);
                  nil_idx <= abs_a[RW-1:0] + RW'(n_args) + RW'(1);
                  c_clr <= 5'(n_args) + 5'd2; st <= S_CALL;
                end else case (lk_tgt)
                  F_GPIO_NEW:
                    if (n_args == 4'd2 && v1.tag == T_INT && rd.tag == T_INT && (rd.val == FLAG_OUT || rd.val == FLAG_IN)) begin
                      // GPIO_init (入力、latch 0) と GPIO_set_dir。pin 32 以上は何もしない
                      gpio_we <= (v1.val < 32'd32); gpio_pin <= v1.val[4:0]; gpio_out_v <= 1'b0;
                      gpio_set_dir <= 1'b1; gpio_dir_v <= (rd.val == FLAG_OUT);
                      we <= 1'b1; wval <= {T_GPIO, v1.val};
                    end else `RITE_ERR
                  F_GPIO_WRITE:
                    if (n_args == 4'd1 && v0.tag == T_GPIO && v1.tag == T_INT && (v1.val == 32'd0 || v1.val == 32'd1)) begin
                      gpio_we <= (v0.val < 32'd32); gpio_pin <= v0.val[4:0]; gpio_out_v <= v1.val[0]; gpio_set_dir <= 1'b0;
                      we <= 1'b1; wval <= {T_INT, 32'd0};
                    end else `RITE_ERR
                  F_SLEEP_MS:
                    if (n_args == 4'd1 && v1.tag == T_INT && !v1.val[31]) begin
                      wake_ms <= ms_now + v1.val;
                      we <= 1'b1; wval <= NIL_V;
                      st <= S_SLEEP;
                    end else `RITE_ERR
                  // module_function(sym): 特異クラスに public で写し、元の行を private にする。R[a] = mod
                  F_MODFUNC:
                    if (n_args == 4'd1 && v0.tag == T_CLASS && v0.val[3:0] == C_KERNEL && v1.tag == T_SYM &&
                        mf_src != 4'd8 && (mf_dst != 4'd8 || mt_n != 4'(NMT))) begin
                      mt_priv[mf_src[2:0]] <= 1'b1;
                      mt_v[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= 1'b1;
                      mt_cls[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= C_KERNEL_S;
                      mt_mid[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= v1.val[3:0];
                      mt_priv[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= 1'b0;
                      mt_irep[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= mt_irep[mf_src[2:0]];
                      mt_tgt[(mf_dst == 4'd8) ? mt_n[2:0] : mf_dst[2:0]] <= mt_tgt[mf_src[2:0]];
                      if (mf_dst == 4'd8) mt_n <= mt_n + 4'd1;
                      we <= 1'b1; wval <= v0;
                    end else `RITE_ERR
                  default: `RITE_ERR
                endcase
              end
              // 枠を降ろし、呼んだ側の R[a] (= この窓の R0) に返す。一番上の枠なら、この .mrb は終わり
              OP_RETURN, OP_RETNIL: begin
                if (sp == 3'd0) begin
                  fbase <= fnext; hdr_i <= '0; acc <= '0; `RITE_NEXT(fnext) st <= S_HDR;
                end else begin
                  we <= 1'b1; widx <= cur_base; wval <= (op == OP_RETURN) ? v0 : NIL_V;
                  sp <= sp - 3'd1;
                  cur_irep <= ci_irep[spm1]; cur_base <= ci_base[spm1]; cur_env <= ci_env[spm1];
                  cur_tc <= ci_tc[spm1]; cur_argc <= ci_argc[spm1]; cur_isblk <= ci_isblk[spm1];
                  `RITE_NEXT(ci_pc[spm1])
                  st <= S_FRAME;
                end
              end
              OP_STOP: begin sp <= '0; fbase <= fnext; hdr_i <= '0; acc <= '0; `RITE_NEXT(fnext) st <= S_HDR; end
              default: `RITE_ERR
            endcase
          end
          // cipush: 今の枠を積み、呼ぶ irep の窓へ移る。窓が 64 本を超えるか、枠が 4 段を超えると範囲の外
          S_CALL: begin
            if (c_base + 7'(ir_nregs[c_irep]) > 7'd64 || sp == 3'(NCI)) `RITE_ERR
            else begin
              ci_irep[sp[1:0]] <= cur_irep; ci_base[sp[1:0]] <= cur_base; ci_env[sp[1:0]] <= cur_env;
              ci_tc[sp[1:0]] <= cur_tc; ci_argc[sp[1:0]] <= cur_argc; ci_isblk[sp[1:0]] <= cur_isblk;
              ci_pc[sp[1:0]] <= ptr;
              sp <= sp + 3'd1;
              cur_irep <= c_irep; cur_base <= c_base[RW-1:0]; cur_env <= c_env; cur_tc <= c_tc; cur_argc <= c_argc;
              cur_isblk <= c_isblk;
              `RITE_NEXT(ir_iseq[c_irep])
              clr_i <= c_base + 7'(c_clr); clr_end <= c_base + 7'(ir_nregs[c_irep]); clr_boot <= 1'b0;
              st <= (c_self == 2'd2) ? S_PRS0 : (c_self == 2'd1) ? S_PWS : c_nil ? S_PWN : S_CLR;
            end
          end
          // ブロックの self: env の R0 を読む
          S_PRS0: begin ridx <= c_env; st <= S_PRS1; end
          S_PRS1: st <= S_PRS2;
          S_PRS2: begin cself <= rd; st <= S_PWS; end
          S_PWS: begin we <= 1'b1; widx <= cur_base; wval <= cself; st <= c_nil ? S_PWN : S_CLR; end
          S_PWN: begin we <= 1'b1; widx <= nil_idx; wval <= NIL_V; st <= S_CLR; end
          // 今の irep の表を写す
          S_FRAME: begin
            cur_symb <= ir_symb[cur_irep]; cur_nsym <= ir_nsym[cur_irep];
            cur_repb <= ir_repb[cur_irep]; cur_rlen <= ir_rlen[cur_irep];
            st <= S_OP;
          end
          S_SLEEP: if ($signed(ms_now - wake_ms) >= 0) st <= S_OP;
          S_HALT:  halted <= 1'b1;
          S_ERR:   error <= 1'b1;
          default: st <= S_ERR;
        endcase
      end
    end
  end
`undef RITE_ERR
`undef RITE_PERR
`undef RITE_NEXT
endmodule
