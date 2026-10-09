// mruby のバイトコード (.mrb、RITE0400) を ROM から直接読んで実行する CPU (issue #4、反復 R3)。
// 範囲は Lチカ (fpga/rite/blink.rb、loop 版) と、それが使う mruby の mrblib (kernel.rb の Kernel#loop) と
// picoruby-gpio の mrblib (gpio.rb の GPIO#initialize ほか) に出る命令とメソッドだけ。範囲の外に当たると error を立てて止まる。
//
// ROM (rake fpga:rite:hex が作る):
// - 起動の像 (tools/fpga/rite_image.rb): mrb_open の C の init が作る状態 (presym、クラス、定数、C の関数のメソッド、main)
// - .mrb を並べたもの (kernel.rb、gpio.rb、blink.rb)。mrb_open が mrblib を読んでから app を読むのと同じく、
//   先頭から 1 つずつ読んで (load.c の read_irep) 実行する。見出しの最初のバイトが 0 なら止まる (halted)
//
// - sym: .mrb の名前を sym の表 (presym + 読んだ名前) と照らして番号を付ける (symbol.c の mrb_intern)。名前は ROM に置いたまま
// - クラス: クラスの表 (superclass、メソッドの表を持つクラス (include の iclass は module)、特異クラス、外側)。
//   メソッドの探索 (class.c の mrb_method_search_vm) は superclass を辿りメソッドの表を順に見る。method cache は無い
// - 定数 (variable.c の mrb_vm_const_get): 外側のクラスを辿り、次に superclass を辿る。object の ivar は (object、sym) の表
// - 呼び出し: vm.c の cipush / OP_RETURN の形。呼ばれた側の R0 は呼んだ側の R[a] (レジスタの窓)。枠は 8 段 (M9K)
// - C の関数 (rite_image_pkg の F_*): Class#new (mrb_instance_new: object を作り initialize を呼ぶ)、gpio.c の _init / set_dir_at /
//   write、Kernel#sleep_ms、Module#module_function / attr_reader、Integer#& | >>、Kernel#===、BasicObject#!
// - 値: nil、false、true、Integer (32bit。mruby の 64bit でない)、Symbol、クラス、object、Proc (irep、env の窓、target class)。
//   env は枠が生きている間だけ (枠の外へ出た Proc は範囲外)
// - ピンの水準は host の板のモデル (firmware-patches/posix-board-gpio.patch) と同じ式: (dir & out) | (~dir & ~pull_down)
// - 時刻: MS_CYCLES の cycle ごとに ms を 1 進める。sleep_ms(n) は呼んだ時の ms + n まで待つ
//
// 表は全部 M9K の形 (rite_ram、同期読み)。読みは「番地を置く → 1 cycle 待つ (rd_wait) → 読める」。速さより小さく浅くする反復
`timescale 1ns / 1ps
module rite_core
  import rite_image_pkg::*;
#(
  parameter int ROM_BYTES = 4096,
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
  localparam int AW = $clog2(ROM_BYTES);
  // 表の大きさ
  localparam int NSYM = 256, NSMAP = 256, NIREP = 32, NREPS = 64, NCLS = 32, NMT = 64, NCONST = 32, NOBJ = 16, NIV = 32,
                 NCI = 8, NREG = 64, NPD = 4;
  localparam int RW = 6, IW = 5;

  // ---- ROM (読み口 2 本) ----
  logic [AW-1:0] rom_addr, rom_addr2;   // 1 本目は ptr (名前を照らす S_IN3 の間は候補の文字)、2 本目は表の名前の文字
  logic [7:0]    rom_q, rom_q2;
  rite_rom #(.BYTES(ROM_BYTES), .FILE(ROM_FILE)) rom (.clk, .addr(rom_addr), .q(rom_q), .addr2(rom_addr2), .q2(rom_q2));

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

  // ---- 値 ----
  localparam logic [2:0] T_NIL = 3'd0, T_FALSE = 3'd1, T_TRUE = 3'd2, T_INT = 3'd3, T_SYM = 3'd4, T_CLASS = 3'd5,
                         T_OBJ = 3'd6, T_PROC = 3'd7;
  typedef struct packed { logic [2:0] tag; logic [31:0] val; } value_t;
  localparam logic [34:0] NIL_V = 35'd0;
  function automatic value_t bool_v(input logic b);
    return b ? {T_TRUE, 32'd0} : {T_FALSE, 32'd0};
  endfunction
  function automatic logic truthy_f(input logic [2:0] tag);
    return tag != T_NIL && tag != T_FALSE;
  endfunction
  // mrb_equal のうち即値と Integer の所 (object 同士は同じ object の時だけ)
  function automatic logic eql_f(input value_t x, input value_t y);
    return x.tag == y.tag && x.val == y.val;
  endfunction

  // ---- 表 (M9K) ----
  // レジスタ
  logic          r_we;  logic [RW-1:0] r_wa, r_ra;  value_t r_wd, r_q;
  rite_ram #(.W(35), .D(NREG)) regs (.clk, .we(r_we), .wa(r_wa), .wd(r_wd), .ra(r_ra), .q(r_q));
  // sym の表: 名前の ROM の番地と長さ
  typedef struct packed { logic [AW-1:0] addr; logic [7:0] len; } sym_t;
  logic          sy_we;  logic [SW-1:0] sy_wa, sy_ra;  sym_t sy_wd, sy_q;
  rite_ram #(.W(AW + 8), .D(NSYM)) symtab (.clk, .we(sy_we), .wa(sy_wa), .wd(sy_wd), .ra(sy_ra), .q(sy_q));
  // irep の中の sym の番号 → sym の番号
  logic          sm_we;  logic [7:0] sm_wa, sm_ra;  logic [SW-1:0] sm_wd, sm_q;
  rite_ram #(.W(SW), .D(NSMAP)) symmap (.clk, .we(sm_we), .wa(sm_wa), .wd(sm_wd), .ra(sm_ra), .q(sm_q));
  // irep (load.c の read_irep が作る mrb_irep の要る所)
  typedef struct packed { logic [AW-1:0] iseq; logic [5:0] nregs; logic [7:0] symb; logic [7:0] nsym; logic [5:0] repb; logic [5:0] rlen; } irep_t;
  logic          ir_we;  logic [IW-1:0] ir_wa, ir_ra;  irep_t ir_wd, ir_q;
  rite_ram #(.W($bits(irep_t)), .D(NIREP)) irtab (.clk, .we(ir_we), .wa(ir_wa), .wd(ir_wd), .ra(ir_ra), .q(ir_q));
  // 子 irep の番号
  logic          rp_we;  logic [5:0] rp_wa, rp_ra;  logic [IW-1:0] rp_wd, rp_q;
  rite_ram #(.W(IW), .D(NREPS)) reps (.clk, .we(rp_we), .wa(rp_wa), .wd(rp_wd), .ra(rp_ra), .q(rp_q));
  // クラス。flags: bit0 module、bit1 特異クラス、bit2 iclass
  typedef struct packed { logic [CW-1:0] sup; logic [CW-1:0] mtc; logic [CW-1:0] scls; logic [CW-1:0] outer; logic [2:0] flags; logic [SW-1:0] name; } cls_t;
  logic          cl_we;  logic [CW-1:0] cl_wa, cl_ra;  cls_t cl_wd;
  /* verilator lint_off UNUSEDSIGNAL */
  cls_t          cl_q;   // name は回路では使わない (inspect の時の名前)
  /* verilator lint_on UNUSEDSIGNAL */
  rite_ram #(.W($bits(cls_t)), .D(NCLS)) clstab (.clk, .we(cl_we), .wa(cl_wa), .wd(cl_wd), .ra(cl_ra), .q(cl_q));
  // メソッド。kind: 0 irep、1 C の関数、2 attr_reader。tgt は irep の番号、関数の番号、ivar の名前の sym
  typedef struct packed { logic [CW-1:0] cls; logic [SW-1:0] mid; logic priv; logic [1:0] kind; logic [7:0] tgt; } mt_t;
  logic          mt_we;  logic [5:0] mt_wa, mt_ra;  mt_t mt_wd, mt_q;
  rite_ram #(.W($bits(mt_t)), .D(NMT)) mttab (.clk, .we(mt_we), .wa(mt_wa), .wd(mt_wd), .ra(mt_ra), .q(mt_q));
  localparam logic [1:0] K_IREP = 2'd0, K_CFUNC = 2'd1, K_ATTR = 2'd2;
  // 定数
  typedef struct packed { logic [CW-1:0] cls; logic [SW-1:0] sym; value_t v; } const_t;
  logic          co_we;  logic [4:0] co_wa, co_ra;  const_t co_wd, co_q;
  rite_ram #(.W($bits(const_t)), .D(NCONST)) contab (.clk, .we(co_we), .wa(co_wa), .wd(co_wd), .ra(co_ra), .q(co_q));
  // object のクラス (0 は main)
  logic          ob_we;  logic [3:0] ob_wa, ob_ra;  logic [CW-1:0] ob_wd, ob_q;
  rite_ram #(.W(CW), .D(NOBJ)) objtab (.clk, .we(ob_we), .wa(ob_wa), .wd(ob_wd), .ra(ob_ra), .q(ob_q));
  // ivar
  typedef struct packed { logic [3:0] obj; logic [SW-1:0] sym; value_t v; } iv_t;
  logic          iv_we;  logic [4:0] iv_wa, iv_ra;  iv_t iv_wd, iv_q;   // iv_wd は (iv_o、iv_s、tv)
  rite_ram #(.W($bits(iv_t)), .D(NIV)) ivtab (.clk, .we(iv_we), .wa(iv_wa), .wd(iv_wd), .ra(iv_ra), .q(iv_q));
  // 呼び出しの枠 (mrb_callinfo の要る所)
  typedef struct packed {
    logic [IW-1:0] irep; logic [AW-1:0] pc; logic [RW-1:0] base, env; logic [CW-1:0] tc; logic [3:0] argc; logic isblk, retself;
  } ci_t;
  logic          ci_we;  logic [2:0] ci_wa, ci_ra;  ci_t ci_wd, ci_q;
  rite_ram #(.W($bits(ci_t)), .D(NCI)) citab (.clk, .we(ci_we), .wa(ci_wa), .wd(ci_wd), .ra(ci_ra), .q(ci_q));

  // 表の数
  logic [SW:0]   sym_n;    // sym の表の次の番号
  logic [8:0]    sm_n;
  logic [IW:0]   ir_n;
  logic [6:0]    rep_n;
  logic [CW:0]   cls_n;
  logic [6:0]    mt_n;
  logic [5:0]    co_n;
  logic [4:0]    ob_n;
  logic [5:0]    iv_n;
  logic [3:0]    sp;

  // ---- GPIO (host の板のモデルと同じ) ----
  localparam logic [31:0] FLAG_IN = 32'd1, FLAG_OUT = 32'd2; // picoruby-gpio/include/gpio.h
  logic [31:0] gpio_out, gpio_dir;
  assign pins = (gpio_dir & gpio_out) | ~gpio_dir;
  logic        gpio_we, gpio_set_dir, gpio_set_out, gpio_out_v, gpio_dir_v;
  logic [4:0]  gpio_pin;
  logic [31:0] gpio_mask;
  assign gpio_mask = 32'd1 << gpio_pin;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      gpio_out <= '0;
      gpio_dir <= '0;
    end else if (gpio_we) begin
      if (gpio_set_out) gpio_out <= gpio_out_v ? (gpio_out | gpio_mask) : (gpio_out & ~gpio_mask);
      if (gpio_set_dir) gpio_dir <= gpio_dir_v ? (gpio_dir | gpio_mask) : (gpio_dir & ~gpio_mask);
    end

  // ---- 命令の番号 (ops.h) ----
  localparam logic [7:0] OP_NOP = 8'd0, OP_MOVE = 8'd1, OP_LOADI8 = 8'd3, OP_LOADINEG = 8'd4, OP_LOADI16 = 8'd14,
                         OP_LOADSYM = 8'd16, OP_LOADNIL = 8'd17, OP_LOADSELF = 8'd18, OP_LOADTRUE = 8'd19,
                         OP_LOADFALSE = 8'd20, OP_GETIV = 8'd25, OP_SETIV = 8'd26, OP_GETCONST = 8'd29,
                         OP_SETCONST = 8'd30, OP_GETMCNST = 8'd31, OP_GETUPVAR = 8'd33, OP_JMP = 8'd38, OP_JMPIF = 8'd39,
                         OP_JMPNOT = 8'd40, OP_SSEND = 8'd47, OP_SSENDB = 8'd49, OP_SEND = 8'd50, OP_SEND0 = 8'd51,
                         OP_BLKCALL = 8'd54, OP_ENTER = 8'd57, OP_RETURN = 8'd61, OP_RETNIL = 8'd64, OP_BLKPUSH = 8'd68,
                         OP_ADD = 8'd69, OP_EQ = 8'd77, OP_LT = 8'd78, OP_BLOCK = 8'd98, OP_CLASS = 8'd103,
                         OP_MODULE = 8'd104, OP_EXEC = 8'd105, OP_TDEF = 8'd107, OP_SDEF = 8'd108, OP_STOP = 8'd118;

  // operand のバイト数 (ops.h の Z / B / BB / S / BS / BBB / W)。範囲の外は 7
  function automatic logic [2:0] opnd_bytes(input logic [7:0] o);
    case (o)
      OP_NOP, OP_RETNIL, OP_STOP:                                                        return 3'd0;
      8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13,
      OP_LOADNIL, OP_LOADSELF, OP_LOADTRUE, OP_LOADFALSE, OP_RETURN, OP_ADD, OP_EQ, OP_LT: return 3'd1;
      OP_MOVE, OP_LOADI8, OP_LOADINEG, OP_LOADSYM, OP_GETIV, OP_SETIV, OP_GETCONST, OP_SETCONST, OP_GETMCNST, OP_JMP,
      OP_SEND0, OP_BLKCALL, OP_BLOCK, OP_CLASS, OP_MODULE, OP_EXEC:                        return 3'd2;
      OP_LOADI16, OP_GETUPVAR, OP_JMPIF, OP_JMPNOT, OP_SSEND, OP_SSENDB, OP_SEND,
      OP_ENTER, OP_BLKPUSH, OP_TDEF, OP_SDEF:                                            return 3'd3;
      default:                                                                           return 3'd7;
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
  // 起動の像の見出し "RIMG" と、節ごとの 1 つのバイト数 (1: クラス、2: 定数、3: メソッド、4: object)
  function automatic logic [7:0] img_magic(input logic [1:0] i);
    case (i) 2'd0: return "R"; 2'd1: return "I"; 2'd2: return "M"; default: return "G"; endcase
  endfunction
  function automatic logic [2:0] img_item(input logic [2:0] sec);
    case (sec) 3'd1: return 3'd6; 3'd2: return 3'd7; 3'd3: return 3'd4; default: return 3'd1; endcase
  endfunction

  // ---- 状態 ----
  typedef enum logic [6:0] {
    S_CLR, S_IMAG, S_ICNT, S_ISYM, S_IITEM,
    S_HDR, S_REC, S_SKIP, S_CATCH, S_PLEN, S_PTT, S_PSTR, S_SLEN, S_SYMLEN, S_IN1, S_IN2, S_IN3, S_INDONE,
    S_IDONE, S_UP, S_START,
    S_OP, S_OPND, S_RD0, S_RD1, S_RD2, S_RD3, S_RD4, S_EXEC,
    S_SEND, S_SCLS_O, S_SCLS_C, S_SENDD, S_NEW2, S_WRITE2, S_MF2, S_MF3, S_MF4, S_SYMRET,
    S_CLS2, S_CLS3, S_CLS4, S_CLS5, S_CLS6, S_MOD2, S_SDEF2, S_CGET2, S_IVGET2,
    S_ENT2, S_CALL, S_CALL2, S_PRS0, S_PRS2, S_PWS, S_PWN, S_FRAME, S_FRAME2, S_RET2,
    S_ML0, S_ML1, S_ML2, S_MD0, S_MD1, S_CL0, S_CL1, S_CL2, S_IVS0, S_IVS1,
    S_SHR, S_SLEEP, S_HALT, S_ERR
  } state_t;
  state_t        st;
  logic          rd_wait;   // 番地を置いた次の cycle (読んだ値がまだ古い)
  logic [AW-1:0] ptr, fbase, fnext;
  logic [4:0]    hdr_i;
  logic [47:0]   acc;       // 見出しの数や operand を集める
  logic [2:0]    cnt;
  logic [2:0]    isec;      // 起動の像の節 (0 sym、1 クラス、2 定数、3 メソッド、4 object)
  logic [7:0]    icnt;      // 節の残りの数
  logic [15:0]   rec_nregs, rec_rlen, rec_clen, pool_left, nsyms;
  logic [AW-1:0] skip_base, skip;   // S_SKIP: ptr = skip_base + skip (1 cycle に加算 1 つ)
  state_t        skip_next;
  irep_t         pir;                // 読んでいる irep
  logic [IW-1:0] pi, file_top;
  logic [5:0]    pslot [0:NPD-1];    // 読みの stack: 親の reps の次に埋める所と、残りの子の数
  logic [5:0]    prem  [0:NPD-1];
  logic [2:0]    pd;
  logic [1:0]    pdm1;
  assign pdm1 = 2'(pd - 3'd1);
  logic [7:0]    sym_i;
  // sym の照合
  logic [AW-1:0] cand_addr, e_addr;
  logic [7:0]    cand_len, ck;
  logic [AW-1:0] cmp_a, cmp_b;
  logic [8:0]    cand_len1;   // 名前と NUL の長さ
  assign cand_len1 = {1'b0, cand_len} + 9'd1;
  logic [SW:0]   sj;

  // 今の枠
  logic [IW-1:0] cur_irep;
  logic [RW-1:0] cur_base, cur_env;
  logic [CW-1:0] cur_tc;
  logic [3:0]    cur_argc;
  logic          cur_isblk, cur_retself;
  value_t        cur_self;
  logic [7:0]    cur_symb, cur_nsym;
  logic [5:0]    cur_repb, cur_rlen;

  // 命令
  logic [7:0]    op, a_q;
  logic [2:0]    nopnd;
  logic [AW-1:0] op_pc;
  logic [31:0]   wake_ms;
  value_t        v0, v1, v2;
  logic [SW-1:0] bsym;       // b の sym (SDEF / TDEF / SETCONST ... の名前)
  logic [IW-1:0] rpid;       // 子 irep の番号 (EXEC / BLOCK / TDEF / SDEF)

  // メソッドの探索 (S_ML*): lk_c から superclass を辿り (lk_mtc、lk_mid) の行を探す。見つからなければ lk_found = 0
  logic [CW-1:0] lk_c, lk_mtc, lk_sup, lk_owner;
  logic [SW-1:0] lk_mid;
  logic          lk_found, lk_priv;
  logic [1:0]    lk_kind;
  logic [7:0]    lk_tgt;
  logic [5:0]    lk_idx, mj;
  state_t        lk_ret;
  logic [2:0]    recv_flags; // 受け手がクラスの時の flags
  // メソッドの定義 (S_MD*): (md_c、md_m) の行を置き換えるか足す
  mt_t           md;
  state_t        md_ret;
  // 定数 (S_CL*): mode 0 外側と superclass、1 superclass、2 そのクラスだけ
  logic [1:0]    cm_mode;
  logic          cm_lex;
  logic [CW-1:0] cm_c, cm_start, cm_key, cm_next;
  logic [SW-1:0] cm_sym;
  logic          cm_found, cm_set;
  value_t        tv;         // 定数と ivar の手順の値 (書く値、読んだ値)
  logic [4:0]    cj;
  state_t        cm_ret;
  // ivar (S_IVS*): (iv_o、iv_s) を読む (iv_set なら書く)
  logic [3:0]    iv_o;
  logic [SW-1:0] iv_s;
  logic          iv_set;
  logic [4:0]    vj;
  assign iv_wd = {iv_o, iv_s, tv};
  state_t        iv_ret;
  // クラスを作る
  logic [CW-1:0] nc_base, nc_sup;
  // 呼び出しの準備 (S_EXEC が置き、S_CALL が枠を積む)
  logic [IW-1:0] c_irep;
  logic [6:0]    c_base;
  logic [RW-1:0] c_env;
  logic [CW-1:0] c_tc;
  logic [3:0]    c_argc;
  logic          c_isblk, c_nil, c_retself, c_top;
  logic [1:0]    c_self;     // 0: そのまま、1: cself を R0 に書く、2: env の R0 を読んで R0 に書く (ブロックの self)
  logic [4:0]    c_clr;      // 窓のここから nregs までを nil で埋める (stack_clear)
  value_t        cself;
  logic [6:0]    clr_i, clr_end;
  logic          clr_boot;
  logic [RW-1:0] nil_idx;
  logic [3:0]    newobj;
  logic [4:0]    shn;        // 残りのずらす数

  // operand: 最初のバイトは a_q、残りは acc に詰める。B: a / BB: a b / S: {a_q, acc} / BS: a S / BBB: a b c / W: {a_q, acc}
  logic [7:0] ob, oc;
  assign ob = (nopnd == 3'd3) ? acc[15:8] : acc[7:0];
  assign oc = acc[7:0];
  logic [6:0] abs_a;
  assign abs_a = 7'(cur_base) + 7'(a_q[4:0]);
  logic [3:0] n_args;       // SEND の引数の数 (c = n | kw<<4)。SEND0 は 0
  assign n_args = (op == OP_SEND0) ? 4'd0 : oc[3:0];
  logic [5:0] blk_off;      // BLKPUSH: m1+r+m2+kd (16=m5:r1:m5:d1:lv4)
  assign blk_off = 6'(acc[15:11]) + 6'(acc[10]) + 6'(acc[9:5]) + 6'(acc[4]);
  logic [23:0] aspec;       // ENTER (24=n1:m5:o5:r1:m5:k5:d1:b1)
  assign aspec = {a_q, acc[15:0]};
  logic [4:0] as_m1, as_o;
  assign as_m1 = aspec[22:18];
  assign as_o  = aspec[17:13];
  logic [4:0] opt_given;    // 渡された省略できる引数の数
  assign opt_given = 5'(cur_argc) - as_m1;

  logic uses_sym, is_send, uses_rep, regop, bad_opnd;
  assign uses_sym = (op == OP_GETCONST || op == OP_GETMCNST || op == OP_SETCONST || op == OP_GETIV || op == OP_SETIV ||
                     op == OP_SSEND || op == OP_SSENDB || op == OP_SEND || op == OP_SEND0 || op == OP_LOADSYM ||
                     op == OP_MODULE || op == OP_CLASS || op == OP_TDEF || op == OP_SDEF);
  assign is_send  = (op == OP_SSEND || op == OP_SSENDB || op == OP_SEND || op == OP_SEND0);
  assign uses_rep = (op == OP_EXEC || op == OP_BLOCK || op == OP_TDEF || op == OP_SDEF);
  assign regop    = (nopnd != 3'd0 && op != OP_JMP && op != OP_ENTER);
  assign bad_opnd = (regop && (a_q[7:5] != 3'd0 || abs_a + 7'd2 > 7'd63)) ||
                    (uses_sym && ob >= cur_nsym) ||
                    (op == OP_MOVE && (ob[7:5] != 3'd0 || 7'(cur_base) + 7'(ob[4:0]) > 7'd63)) ||
                    (is_send && ((op != OP_SEND0 && (oc[7:4] != 4'd0 || n_args == 4'd15)) || abs_a + 7'(n_args) + 7'd1 > 7'd63)) ||
                    (op == OP_GETUPVAR && (oc != 8'd0 || !cur_isblk || ob[7:5] != 3'd0 ||
                                           7'(cur_env) + 7'(ob[4:0]) > 7'd63)) ||
                    (op == OP_BLKPUSH && (acc[3:0] != 4'd0 || 7'(cur_base) + 7'(blk_off) + 7'd1 > 7'd63)) ||
                    (op == OP_BLKCALL && (ob[7:4] != 4'd0 || abs_a + 7'(ob[3:0]) > 7'd63)) ||
                    (uses_rep && (((op == OP_TDEF || op == OP_SDEF) ? oc : ob) >= 8'(cur_rlen)));

  // 命令を実行する cycle (テストベンチの +TRACE が見る。回路の中では使わない)
  /* verilator lint_off UNUSEDSIGNAL */
  logic in_exec;
  assign in_exec = (st == S_EXEC) && !rd_wait;
  /* verilator lint_on UNUSEDSIGNAL */

  assign rom_addr  = (st == S_IN3) ? cmp_a : ptr;
  assign rom_addr2 = cmp_b;

  // 命令の飛び先: JMP は S、JMPIF / JMPNOT は BS の S、ENTER は省略できる引数の飛び (渡された数 * 3、全部なら o * 3)
  logic [AW-1:0] joff, jmp_to;
  assign joff = (op == OP_JMP) ? AW'({a_q, acc[7:0]}) :
                (op == OP_ENTER) ? AW'(5'((st == S_ENT2) ? opt_given : as_o)) * AW'(3) : AW'(acc[15:0]);
  assign jmp_to = ptr + joff;

  logic [2:0] q_nb;         // rom_q の命令の operand のバイト数
  assign q_nb = opnd_bytes(rom_q);
  value_t recv;
  assign recv = (op == OP_SSEND || op == OP_SSENDB) ? cur_self : v0;
  // 等しさは 1 つ (OP_EQ と Kernel#=== は R[a] と R[a+1])
  logic eq01;
  assign eq01 = eql_f(v0, v1);
  logic [31:0] addsum;
  assign addsum = v0.val + v1.val;

  // 即値のクラス (object とクラスは表を読む)
  function automatic logic [CW-1:0] imm_class(input logic [2:0] tag);
    case (tag)
      T_NIL:   return C_NIL;
      T_FALSE: return C_FALSE;
      T_TRUE:  return C_TRUE;
      T_INT:   return C_INTEGER;
      T_SYM:   return C_SYMBOL;
      T_PROC:  return C_PROC;
      default: return '0;
    endcase
  endfunction

`define RITE_ERR begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
`define RITE_PERR begin st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr); end
`define RITE_NEXT(p) begin ptr <= (p); rd_wait <= 1'b1; end
// レジスタに書く (今の枠の R0 なら、書き口で self も変わる)
`define RITE_WREG(i, v) begin r_we <= 1'b1; r_wa <= (i); r_wd <= (v); end
`define RITE_WA(v) `RITE_WREG(abs_a[RW-1:0], v)
// 表を探す副の手順を呼ぶ
`define RITE_MLOOK(c, m, r) begin lk_c <= (c); lk_mid <= (m); lk_ret <= (r); st <= S_ML0; end
`define RITE_MDEF(c, m, k, t, p, r) begin md <= {(c), (m), (p), (k), (t)}; md_ret <= (r); st <= S_MD0; end
`define RITE_CLOOK(mode, c, s, r) begin cm_mode <= (mode); cm_lex <= ((mode) == 2'd0); cm_c <= (c); cm_start <= (c); cm_sym <= (s); cm_set <= 1'b0; cm_ret <= (r); st <= S_CL0; end
`define RITE_CSET(c, s, v, r) begin cm_mode <= 2'd2; cm_lex <= 1'b0; cm_c <= (c); cm_start <= (c); cm_sym <= (s); cm_set <= 1'b1; tv <= (v); cm_ret <= (r); st <= S_CL0; end
`define RITE_IV(o, s, set, v, r) begin iv_o <= (o); iv_s <= (s); iv_set <= (set); tv <= (v); iv_ret <= (r); st <= S_IVS0; end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_CLR; clr_boot <= 1'b1; clr_i <= '0; clr_end <= 7'd64;
      rd_wait <= 1'b1; ptr <= '0; cmp_a <= '0; cmp_b <= '0; fbase <= '0; fnext <= '0; hdr_i <= '0;
      acc <= '0; cnt <= '0; isec <= '0; icnt <= '0; skip_base <= '0; skip <= '0; skip_next <= S_CLR;
      rec_nregs <= '0; rec_rlen <= '0; rec_clen <= '0; pool_left <= '0; nsyms <= '0;
      pir <= '0; pi <= '0; file_top <= '0; pd <= '0; sym_i <= '0; cand_addr <= '0; e_addr <= '0; cand_len <= '0;
      ck <= '0; sj <= '0;
      for (int i = 0; i < NPD; i++) begin pslot[i] <= '0; prem[i] <= '0; end
      cur_irep <= '0; cur_base <= '0; cur_env <= '0; cur_tc <= C_OBJECT; cur_argc <= '0; cur_isblk <= 1'b0;
      cur_retself <= 1'b0; cur_self <= {T_OBJ, 32'd0}; cur_symb <= '0; cur_nsym <= '0; cur_repb <= '0; cur_rlen <= '0;
      op <= '0; a_q <= '0; nopnd <= '0; op_pc <= '0; wake_ms <= '0;
      v0 <= NIL_V; v1 <= NIL_V; v2 <= NIL_V;  bsym <= '0; rpid <= '0;
      lk_c <= '0; lk_mtc <= '0; lk_sup <= '0; lk_owner <= '0; lk_mid <= '0; lk_found <= 1'b0; lk_priv <= 1'b0;
      lk_kind <= '0; lk_tgt <= '0; lk_idx <= '0; mj <= '0; lk_ret <= S_ERR; recv_flags <= '0;
      md <= '0; md_ret <= S_ERR;
      cm_mode <= '0; cm_lex <= 1'b0; cm_c <= '0; cm_start <= '0; cm_key <= '0; cm_next <= '0; cm_sym <= '0;
      cm_found <= 1'b0; cm_set <= 1'b0; tv <= NIL_V; cj <= '0; cm_ret <= S_ERR;
      iv_o <= '0; iv_s <= '0; iv_set <= 1'b0; vj <= '0; iv_ret <= S_ERR;
      nc_base <= '0; nc_sup <= '0;
      c_irep <= '0; c_base <= '0; c_env <= '0; c_tc <= '0; c_argc <= '0; c_isblk <= 1'b0; c_nil <= 1'b0;
      c_retself <= 1'b0; c_top <= 1'b0; c_self <= '0; c_clr <= '0; cself <= NIL_V; nil_idx <= '0; newobj <= '0; shn <= '0;
      r_we <= 1'b0; r_wa <= '0; r_ra <= '0; r_wd <= NIL_V;
      sy_we <= 1'b0; sy_wa <= '0; sy_ra <= '0; sy_wd <= '0;
      sm_we <= 1'b0; sm_wa <= '0; sm_ra <= '0; sm_wd <= '0;
      ir_we <= 1'b0; ir_wa <= '0; ir_ra <= '0; ir_wd <= '0;
      rp_we <= 1'b0; rp_wa <= '0; rp_ra <= '0; rp_wd <= '0;
      cl_we <= 1'b0; cl_wa <= '0; cl_ra <= '0; cl_wd <= '0;
      mt_we <= 1'b0; mt_wa <= '0; mt_ra <= '0; mt_wd <= '0;
      co_we <= 1'b0; co_wa <= '0; co_ra <= '0; co_wd <= '0;
      ob_we <= 1'b0; ob_wa <= '0; ob_ra <= '0; ob_wd <= '0;
      iv_we <= 1'b0; iv_wa <= '0; iv_ra <= '0;
      ci_we <= 1'b0; ci_wa <= '0; ci_ra <= '0; ci_wd <= '0;
      sym_n <= 9'd1; sm_n <= '0; ir_n <= '0; rep_n <= '0; cls_n <= 6'd1; mt_n <= '0; co_n <= '0; ob_n <= '0; iv_n <= '0;
      sp <= '0;
      gpio_we <= 1'b0; gpio_set_dir <= 1'b0; gpio_set_out <= 1'b0; gpio_out_v <= 1'b0; gpio_dir_v <= 1'b0; gpio_pin <= '0;
      halted <= 1'b0; error <= 1'b0; error_op <= '0; error_pc <= '0;
    end else begin
      r_we <= 1'b0; sy_we <= 1'b0; sm_we <= 1'b0; ir_we <= 1'b0; rp_we <= 1'b0; cl_we <= 1'b0; mt_we <= 1'b0;
      co_we <= 1'b0; ob_we <= 1'b0; iv_we <= 1'b0; ci_we <= 1'b0;
      gpio_we <= 1'b0;
      // 今の枠の R0 に書いたら self も変える (下の状態の代入が後に勝つ)
      if (r_we && r_wa == cur_base) cur_self <= r_wd;
      if (rd_wait) begin
        rd_wait <= 1'b0;   // 読んだ値は次の cycle に揃う
      end else begin
        case (st)
          // レジスタを clr_i から clr_end の前まで nil にする (起動と、呼び出しの stack_clear)
          S_CLR: begin
            if (clr_i >= clr_end) st <= clr_boot ? S_IMAG : S_FRAME;
            else begin `RITE_WREG(clr_i[RW-1:0], NIL_V) clr_i <= clr_i + 7'd1; end
          end

          // ---- 起動の像 (tools/fpga/rite_image.rb) ----
          S_IMAG: begin
            if (rom_q != img_magic(hdr_i[1:0])) `RITE_PERR
            else if (hdr_i == 5'd3) begin isec <= '0; `RITE_NEXT(ptr + AW'(1)) st <= S_ICNT; end
            else begin hdr_i <= hdr_i + 5'd1; `RITE_NEXT(ptr + AW'(1)) end
          end
          // 節の数。0 なら次の節。object の節の後は .mrb
          S_ICNT: begin
            icnt <= rom_q; cnt <= '0; acc <= '0;
            `RITE_NEXT(ptr + AW'(1))
            if (rom_q == 8'd0) begin
              if (isec == 3'd4) begin fbase <= ptr + AW'(1); hdr_i <= '0; st <= S_HDR; end
              else isec <= isec + 3'd1;
            end else st <= (isec == 3'd0) ? S_ISYM : S_IITEM;
          end
          // presym の 1 つ: 長さと名前。表には名前の番地と長さを置く
          S_ISYM: begin
            if (sym_n == 9'(NSYM)) `RITE_PERR
            else begin
              sy_we <= 1'b1; sy_wa <= sym_n[SW-1:0]; sy_wd <= {ptr + AW'(1), rom_q}; sym_n <= sym_n + 9'd1;
              skip_base <= ptr + AW'(1); skip <= AW'(rom_q); st <= S_SKIP;
              icnt <= icnt - 8'd1;
              skip_next <= (icnt == 8'd1) ? S_ICNT : S_ISYM;
              if (icnt == 8'd1) isec <= 3'd1;
            end
          end
          // クラス / 定数 / メソッド / object の 1 つ (img_item バイト)
          S_IITEM: begin
            acc <= {acc[39:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt + 3'd1 == img_item(isec)) begin
              cnt <= '0;
              case (isec)
                3'd1: begin   // super mtc sclass outer flags name
                  cl_we <= 1'b1; cl_wa <= cls_n[CW-1:0];
                  cl_wd <= {acc[CW-1+32:32], acc[CW-1+24:24], acc[CW-1+16:16], acc[CW-1+8:8], acc[2:0], rom_q};
                  cls_n <= cls_n + 6'd1;
                end
                3'd2: begin   // cls sym tag val
                  co_we <= 1'b1; co_wa <= co_n[4:0];
                  co_wd <= {CW'(acc[47:40]), acc[39:32], acc[26:24], acc[23:0], rom_q};
                  co_n <= co_n + 6'd1;
                end
                3'd3: begin   // cls mid flags tgt
                  mt_we <= 1'b1; mt_wa <= mt_n[5:0];
                  mt_wd <= {acc[CW-1+16:16], acc[15:8], acc[7], acc[6:5], rom_q};
                  mt_n <= mt_n + 7'd1;
                end
                default: begin ob_we <= 1'b1; ob_wa <= ob_n[3:0]; ob_wd <= rom_q[CW-1:0]; ob_n <= ob_n + 5'd1; end
              endcase
              icnt <= icnt - 8'd1;
              // object の節 (最後) の後は .mrb
              if (icnt == 8'd1 && isec == 3'd4) begin fbase <= ptr + AW'(1); hdr_i <= '0; st <= S_HDR; end
              else if (icnt == 8'd1) begin isec <= isec + 3'd1; st <= S_ICNT; end
            end else cnt <= cnt + 3'd1;
          end

          // ---- .mrb を読む (load.c の read_irep) ----
          // 見出し 0..23: "RITE0400"、size (8..11)、"IREP"。最初のバイトが 0 なら、もう .mrb は無い
          S_HDR: begin
            if (hdr_i == 5'd0 && rom_q == 8'd0) st <= S_HALT;
            else if (!hdr_ok(hdr_i, rom_q)) `RITE_PERR
            else begin
              acc <= {acc[39:0], rom_q};
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
            acc <= {acc[39:0], rom_q};
            if (hdr_i == 5'd7)  rec_nregs <= {acc[7:0], rom_q};
            if (hdr_i == 5'd9)  rec_rlen  <= {acc[7:0], rom_q};
            if (hdr_i == 5'd11) rec_clen  <= {acc[7:0], rom_q};
            if (hdr_i == 5'd15) begin
              if (acc[23:8] != 16'd0 || ir_n == 6'(NIREP) || rec_nregs == 16'd0 || rec_nregs > 16'd32 ||
                  16'(rep_n) + rec_rlen > 16'(NREPS) || (pd != 3'd0 && prem[pdm1] == 6'd0)) `RITE_PERR
              else begin
                pir <= {ptr + AW'(1), rec_nregs[5:0], 8'd0, 8'd0, rep_n[5:0], rec_rlen[5:0]};
                rep_n <= rep_n + 7'(rec_rlen[5:0]);
                pi <= ir_n[IW-1:0];
                ir_n <= ir_n + 6'd1;
                if (pd == 3'd0) file_top <= ir_n[IW-1:0];
                else begin
                  rp_we <= 1'b1; rp_wa <= pslot[pdm1]; rp_wd <= ir_n[IW-1:0];
                  pslot[pdm1] <= pslot[pdm1] + 6'd1;
                  prem[pdm1] <= prem[pdm1] - 6'd1;
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
            else begin rec_clen <= rec_clen - 16'd1; skip_base <= ptr; skip <= AW'(13); skip_next <= S_CATCH; st <= S_SKIP; end
          end
          // pool の数
          S_PLEN: begin
            acc <= {acc[39:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt == 3'd1) begin
              pool_left <= {acc[7:0], rom_q}; cnt <= '0; acc <= '0;
              st <= ({acc[7:0], rom_q} == 16'd0) ? S_SLEN : S_PTT;
            end else cnt <= cnt + 3'd1;
          end
          // pool の 1 つ: 種類で長さが決まる。文字列の中身は使わないので飛ばす
          S_PTT: begin
            case (rom_q)
              8'd0, 8'd2: begin `RITE_NEXT(ptr + AW'(1)) cnt <= '0; acc <= '0; st <= S_PSTR; end   // STR / SSTR
              8'd1: begin                                                                             // INT32
                skip_base <= ptr; skip <= AW'(5); st <= S_SKIP; pool_left <= pool_left - 16'd1;
                skip_next <= (pool_left == 16'd1) ? S_SLEN : S_PTT;
              end
              8'd3, 8'd5: begin                                                                       // INT64 / FLOAT
                skip_base <= ptr; skip <= AW'(9); st <= S_SKIP; pool_left <= pool_left - 16'd1;
                skip_next <= (pool_left == 16'd1) ? S_SLEN : S_PTT;
              end
              default: `RITE_PERR
            endcase
          end
          // 文字列の長さ (2 バイト)、中身、NUL
          S_PSTR: begin
            acc <= {acc[39:0], rom_q};
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
            acc <= {acc[39:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt == 3'd1) begin
              nsyms <= {acc[7:0], rom_q}; sym_i <= '0; cnt <= '0; acc <= '0;
              pir.symb <= sm_n[7:0]; pir.nsym <= rom_q;
              if (acc[7:0] != 8'd0 || {acc[7:0], rom_q} > 16'(NSMAP) - 16'(sm_n)) `RITE_PERR   // irep の sym の表に入らない
              else st <= ({acc[7:0], rom_q} == 16'd0) ? S_IDONE : S_SYMLEN;
            end else cnt <= cnt + 3'd1;
          end
          // 1 つの sym の長さ (2 バイト、0xFFFF は名前の無い sym)。名前は sym の表と照らす (S_IN*)
          S_SYMLEN: begin
            acc <= {acc[39:0], rom_q};
            if (cnt == 3'd1) begin
              cnt <= '0; acc <= '0;
              if ({acc[7:0], rom_q} == 16'hFFFF) begin
                sm_we <= 1'b1; sm_wa <= 8'(sm_n + 9'(sym_i)); sm_wd <= '0;
                `RITE_NEXT(ptr + AW'(1))
                if (16'(sym_i) + 16'd1 == nsyms) begin sm_n <= sm_n + 9'(nsyms); st <= S_IDONE; end
                else sym_i <= sym_i + 8'd1;
              end else if (acc[7:0] != 8'd0) `RITE_PERR   // 255 文字を超える名前は範囲の外
              else begin
                cand_addr <= ptr + AW'(1); cand_len <= rom_q;
                if (sym_n == 9'd1) begin sj <= 9'd1; st <= S_INDONE; end
                else begin sj <= 9'd1; sy_ra <= 8'd1; rd_wait <= 1'b1; st <= S_IN1; end
              end
            end else begin
              cnt <= cnt + 3'd1; `RITE_NEXT(ptr + AW'(1))
            end
          end
          // 表の sj 番の長さを比べる。違えば次、同じなら 1 文字ずつ (S_IN2 / S_IN3)。表の終わりまで無ければ足す
          S_IN1: begin
            if (sy_q.len == cand_len) begin ck <= '0; e_addr <= sy_q.addr; st <= S_IN2; end
            else if (sj + 9'd1 == sym_n) begin sj <= sym_n; st <= S_INDONE; end
            else begin sj <= sj + 9'd1; sy_ra <= 8'(sj + 9'd1); rd_wait <= 1'b1; end
          end
          S_IN2: begin
            if (ck == cand_len) st <= S_INDONE;   // 同じ名前
            else begin cmp_a <= cand_addr + AW'(ck); cmp_b <= e_addr + AW'(ck); rd_wait <= 1'b1; st <= S_IN3; end
          end
          S_IN3: begin
            if (rom_q == rom_q2) begin ck <= ck + 8'd1; st <= S_IN2; end
            else if (sj + 9'd1 == sym_n) begin sj <= sym_n; st <= S_INDONE; end
            else begin sj <= sj + 9'd1; sy_ra <= 8'(sj + 9'd1); rd_wait <= 1'b1; st <= S_IN1; end
          end
          // sj が番号 (sym_n なら新しい名前を足す)。名前と NUL の後へ
          S_INDONE: begin
            if (sj == sym_n) begin
              if (sym_n == 9'(NSYM)) `RITE_PERR
              else begin sy_we <= 1'b1; sy_wa <= sym_n[SW-1:0]; sy_wd <= {cand_addr, cand_len}; sym_n <= sym_n + 9'd1; end
            end
            sm_we <= 1'b1; sm_wa <= 8'(sm_n + 9'(sym_i)); sm_wd <= sj[SW-1:0];
            skip_base <= cand_addr; skip <= AW'(cand_len1); st <= S_SKIP;   // 名前と NUL の後へ
            if (16'(sym_i) + 16'd1 == nsyms) begin sm_n <= sm_n + 9'(nsyms); skip_next <= S_IDONE; end
            else begin sym_i <= sym_i + 8'd1; skip_next <= S_SYMLEN; end
          end
          // 1 つの irep を読み終えた: 表に置く。子があれば読みの stack に積んで子へ
          S_IDONE: begin
            ir_we <= 1'b1; ir_wa <= pi; ir_wd <= pir;
            if (rec_rlen != 16'd0) begin
              if (pd == 3'(NPD)) `RITE_PERR
              else begin
                pslot[pd[1:0]] <= pir.repb; prem[pd[1:0]] <= rec_rlen[5:0]; pd <= pd + 3'd1;
                hdr_i <= '0; acc <= '0; st <= S_REC;
              end
            end else st <= S_UP;
          end
          // 子を読み終えた親を stack から降ろす。空になったら .mrb の一番上の irep を実行する
          S_UP: begin
            if (pd == 3'd0) st <= S_START;
            else if (prem[pdm1] == 6'd0) pd <= pd - 3'd1;
            else begin hdr_i <= '0; acc <= '0; st <= S_REC; end
          end
          // 一番上の枠: self は main、target class は Object
          S_START: begin
            sp <= '0; cur_irep <= file_top; cur_base <= '0; cur_env <= '0; cur_tc <= C_OBJECT; cur_argc <= '0;
            cur_isblk <= 1'b0; cur_retself <= 1'b0;
            c_irep <= file_top; c_base <= '0; c_tc <= C_OBJECT; c_env <= '0; c_isblk <= 1'b0; c_argc <= '0;
            c_retself <= 1'b0; c_top <= 1'b1; c_self <= 2'd1; cself <= {T_OBJ, 32'd0}; c_nil <= 1'b0; c_clr <= 5'd1;
            ir_ra <= file_top; rd_wait <= 1'b1; clr_boot <= 1'b0;
            st <= S_CALL2;
          end

          // ---- 実行 ----
          S_OP: begin
            op <= rom_q; op_pc <= ptr; nopnd <= q_nb; cnt <= '0; acc <= '0; a_q <= '0;
            `RITE_NEXT(ptr + AW'(1))
            if (q_nb == 3'd7) begin
              st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr);
            end else if (q_nb == 3'd0) st <= S_RD0;
            else st <= S_OPND;
          end
          S_OPND: begin
            if (cnt == 3'd0) a_q <= rom_q; else acc <= {acc[39:0], rom_q};
            `RITE_NEXT(ptr + AW'(1))
            if (cnt + 3'd1 == nopnd) st <= S_RD0;
            cnt <= cnt + 3'd1;
          end
          // レジスタを読む: MOVE は b、GETUPVAR は env の b、BLKPUSH はブロックの引数、ほかは a。続けて a+1、a+2。
          // 同時に sym の番号と子 irep の番号を読む
          S_RD0: begin
            sm_ra <= cur_symb + ob;
            rp_ra <= cur_repb + 6'((op == OP_TDEF || op == OP_SDEF) ? oc : ob);
            if (bad_opnd) `RITE_ERR
            else begin
              case (op)
                OP_MOVE:     r_ra <= cur_base + RW'(ob);
                OP_GETUPVAR: r_ra <= cur_env + RW'(ob);
                OP_BLKPUSH:  r_ra <= cur_base + RW'(blk_off) + RW'(1);
                default:     r_ra <= abs_a[RW-1:0];
              endcase
              st <= S_RD1;
            end
          end
          S_RD1: begin r_ra <= abs_a[RW-1:0] + RW'(1); st <= S_RD2; end
          S_RD2: begin v0 <= r_q; r_ra <= abs_a[RW-1:0] + RW'(2); st <= S_RD3; end
          S_RD3: begin v1 <= r_q; bsym <= sm_q; rpid <= rp_q; st <= S_RD4; end
          S_RD4: begin
            v2 <= r_q;
            st <= is_send ? S_SEND : S_EXEC;
          end
          S_EXEC: begin
            st <= S_OP;   // 次の命令は ptr から
            case (op)
              OP_NOP: ;
              OP_MOVE, OP_GETUPVAR: `RITE_WA(v0)
              OP_LOADSELF:  `RITE_WA(cur_self)
              OP_LOADI8:    `RITE_WA(value_t'({T_INT, {24'd0, ob}}))
              OP_LOADINEG:  `RITE_WA(value_t'({T_INT, -{24'd0, ob}}))
              8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13:                  // LOADI__1..LOADI_7
                            `RITE_WA(value_t'({T_INT, 32'(op) - 32'd6}))
              OP_LOADI16:   `RITE_WA(value_t'({T_INT, {{16{acc[15]}}, acc[15:0]}}))
              OP_LOADSYM:   `RITE_WA(value_t'({T_SYM, 24'd0, bsym}))
              OP_LOADNIL:   `RITE_WA(NIL_V)
              OP_LOADTRUE:  `RITE_WA(bool_v(1'b1))
              OP_LOADFALSE: `RITE_WA(bool_v(1'b0))
              OP_JMP:       `RITE_NEXT(jmp_to)
              OP_JMPIF:     if (truthy_f(v0.tag))  `RITE_NEXT(jmp_to)
              OP_JMPNOT:    if (!truthy_f(v0.tag)) `RITE_NEXT(jmp_to)
              // vm_op_blkpush: lv 0 の枠のブロックの引数。nil なら LocalJumpError (範囲の外)
              OP_BLKPUSH:   if (v0.tag == T_NIL) `RITE_ERR else `RITE_WA(v0)
              OP_BLOCK:     `RITE_WA(value_t'({T_PROC, 11'd0, cur_tc, 2'd0, cur_base, 3'd0, rpid}))
              // OP_EQ / OP_LT / OP_ADD: Integer 同士の速い道。EQ は同じ即値や同じ object も (mrb_obj_eq)。ほかは範囲の外
              OP_EQ: begin
                if ((v0.tag == T_INT && v1.tag == T_INT) || eq01) `RITE_WA(bool_v(eq01))
                else if (v0.tag == T_INT || v1.tag == T_INT) `RITE_WA(bool_v(1'b0))   // Integer#== は数でなければ false
                else `RITE_ERR
              end
              OP_LT:  if (v0.tag == T_INT && v1.tag == T_INT) `RITE_WA(bool_v($signed(v0.val) < $signed(v1.val))) else `RITE_ERR
              OP_ADD: begin
                if (v0.tag != T_INT || v1.tag != T_INT) `RITE_ERR
                else if (v0.val[31] == v1.val[31] && addsum[31] != v0.val[31]) `RITE_ERR  // 32bit を超える
                else `RITE_WA(value_t'({T_INT, addsum}))
              end
              // ivar: self は object だけ
              OP_GETIV: if (cur_self.tag != T_OBJ) `RITE_ERR else `RITE_IV(cur_self.val[3:0], bsym, 1'b0, NIL_V, S_IVGET2)
              OP_SETIV: if (cur_self.tag != T_OBJ) `RITE_ERR else `RITE_IV(cur_self.val[3:0], bsym, 1'b1, v0, S_OP)
              OP_GETCONST: `RITE_CLOOK(2'd0, cur_tc, bsym, S_CGET2)
              OP_GETMCNST: if (v0.tag != T_CLASS) `RITE_ERR else `RITE_CLOOK(2'd1, v0.val[CW-1:0], bsym, S_CGET2)
              OP_SETCONST: `RITE_CSET(cur_tc, bsym, v0, S_OP)
              // mrb_vm_define_class: 基が nil なら target class。同じ名前の定数がそのクラスにあれば開き直す
              OP_CLASS: begin
                if ((v0.tag != T_NIL && v0.tag != T_CLASS) || (v1.tag != T_NIL && v1.tag != T_CLASS)) `RITE_ERR
                else begin
                  nc_base <= (v0.tag == T_NIL) ? cur_tc : v0.val[CW-1:0];
                  nc_sup <= (v1.tag == T_NIL) ? '0 : v1.val[CW-1:0];
                  `RITE_CLOOK(2'd2, (v0.tag == T_NIL) ? cur_tc : v0.val[CW-1:0], bsym, S_CLS2)
                end
              end
              // mrb_vm_define_module: 開き直すだけ (新しい module は範囲の外)
              OP_MODULE: begin
                if (v0.tag != T_NIL && v0.tag != T_CLASS) `RITE_ERR
                else `RITE_CLOOK(2'd2, (v0.tag == T_NIL) ? cur_tc : v0.val[CW-1:0], bsym, S_MOD2)
              end
              // 引数の形は必須、省略できるもの、ブロック。ブロックの枠は必須だけで数が同じ時だけ
              OP_ENTER: begin
                if ((aspec & 24'h801FFE) != 24'd0) `RITE_ERR
                else if (cur_isblk ? (as_o != 5'd0 || 5'(cur_argc) != as_m1)
                                   : (5'(cur_argc) < as_m1 || 6'(cur_argc) > 6'(as_m1) + 6'(as_o))) `RITE_ERR
                else if (6'(cur_argc) == 6'(as_m1) + 6'(as_o)) begin
                  if (as_o != 5'd0) `RITE_NEXT(jmp_to)
                end else begin
                  // 省略された引数がある: ブロックを R[m1+o+1] へ移し、(argc-m1)*3 だけ進む
                  r_ra <= cur_base + RW'(cur_argc) + RW'(1); rd_wait <= 1'b1; st <= S_ENT2;
                end
              end
              OP_TDEF: `RITE_MDEF(cur_tc, bsym, K_IREP, 8'(rpid), 1'b0, S_SYMRET)
              OP_SDEF: begin
                if (v0.tag != T_CLASS) `RITE_ERR
                else begin cl_ra <= v0.val[CW-1:0]; rd_wait <= 1'b1; st <= S_SDEF2; end
              end
              // blockexec: R[a] (クラスかモジュール) を self と target class にして子 irep を呼ぶ
              OP_EXEC: begin
                if (v0.tag != T_CLASS) `RITE_ERR
                else begin
                  c_irep <= rpid; c_base <= abs_a; c_tc <= v0.val[CW-1:0]; c_env <= '0; c_isblk <= 1'b0; c_argc <= '0;
                  c_self <= 2'd0; c_nil <= 1'b0; c_retself <= 1'b0; c_top <= 1'b0; c_clr <= 5'd1; st <= S_CALL;
                end
              end
              // R[a].call(R[a+1]..R[a+b]): self は env の R0
              OP_BLKCALL: begin
                if (v0.tag != T_PROC) `RITE_ERR
                else begin
                  c_irep <= v0.val[IW-1:0]; c_base <= abs_a; c_tc <= v0.val[CW-1+16:16]; c_env <= v0.val[13:8];
                  c_isblk <= 1'b1; c_argc <= ob[3:0]; c_self <= 2'd2; c_nil <= 1'b0; c_retself <= 1'b0; c_top <= 1'b0;
                  c_clr <= 5'(ob[3:0]) + 5'd1; st <= S_CALL;
                end
              end
              // 枠を降ろし、呼んだ側の R[a] (= この窓の R0) に返す。Class#new の initialize は object を返す
              OP_RETURN, OP_RETNIL: begin
                if (sp == 4'd0) begin
                  fbase <= fnext; hdr_i <= '0; acc <= '0; `RITE_NEXT(fnext) st <= S_HDR;
                end else begin
                  `RITE_WREG(cur_base, cur_retself ? cur_self : (op == OP_RETURN) ? v0 : value_t'(NIL_V))
                  ci_ra <= 3'(sp - 4'd1); rd_wait <= 1'b1; st <= S_RET2;
                end
              end
              OP_STOP: begin sp <= '0; fbase <= fnext; hdr_i <= '0; acc <= '0; `RITE_NEXT(fnext) st <= S_HDR; end
              default: `RITE_ERR
            endcase
          end

          // ---- メソッドの呼び出し ----
          // 受け手のクラス: 即値は決まったクラス、object は表、クラスは特異クラス (無ければ Class か Module)
          S_SEND: begin
            if (recv.tag == T_OBJ) begin ob_ra <= recv.val[3:0]; rd_wait <= 1'b1; st <= S_SCLS_O; end
            else if (recv.tag == T_CLASS) begin cl_ra <= recv.val[CW-1:0]; rd_wait <= 1'b1; st <= S_SCLS_C; end
            else `RITE_MLOOK(imm_class(recv.tag), bsym, S_SENDD)
          end
          S_SCLS_O: `RITE_MLOOK(ob_q, bsym, S_SENDD)
          S_SCLS_C: begin
            recv_flags <= cl_q.flags;
            `RITE_MLOOK((cl_q.scls != '0) ? cl_q.scls : cl_q.flags[0] ? C_MODULE : C_CLASS, bsym, S_SENDD)
          end
          S_SENDD: begin
            st <= S_OP;
            if (!lk_found) `RITE_ERR                                   // method_missing は範囲の外
            else if ((op == OP_SEND || op == OP_SEND0) && lk_priv) `RITE_ERR  // private を受け手付きで呼んだ
            else if (lk_kind == K_IREP) begin
              // SSEND は R[a] を self にする。ブロックの無い SEND は R[a+n+1] を nil にする
              c_irep <= lk_tgt[IW-1:0]; c_base <= abs_a; c_tc <= lk_owner; c_env <= '0; c_isblk <= 1'b0;
              c_argc <= n_args; c_self <= (op == OP_SSEND || op == OP_SSENDB) ? 2'd1 : 2'd0; cself <= recv;
              c_nil <= (op != OP_SSENDB); c_retself <= 1'b0; c_top <= 1'b0;
              nil_idx <= abs_a[RW-1:0] + RW'(n_args) + RW'(1);
              c_clr <= 5'(n_args) + 5'd2; st <= S_CALL;
            end else if (lk_kind != K_CFUNC) `RITE_ERR               // attr_reader の読み手は R4 で
            else case (FW'(lk_tgt))
              // mrb_instance_new: object を作り、initialize を探す
              F_NEW: begin
                if (recv.tag != T_CLASS || recv_flags != 3'd0 || ob_n == 5'(NOBJ)) `RITE_ERR
                else begin
                  ob_we <= 1'b1; ob_wa <= ob_n[3:0]; ob_wd <= recv.val[CW-1:0]; newobj <= ob_n[3:0]; ob_n <= ob_n + 5'd1;
                  `RITE_MLOOK(recv.val[CW-1:0], N_INITIALIZE, S_NEW2)
                end
              end
              F_DO_NOTHING: `RITE_WA(NIL_V)
              // gpio.c: GPIO_init (入力、latch 0)。pin 32 以上は何もしない (板のモデルと同じ)
              F_UINIT:
                if (n_args == 4'd1 && v1.tag == T_INT) begin
                  gpio_we <= (v1.val < 32'd32); gpio_pin <= v1.val[4:0]; gpio_set_out <= 1'b1; gpio_out_v <= 1'b0;
                  gpio_set_dir <= 1'b1; gpio_dir_v <= 1'b0;
                  `RITE_WA(value_t'({T_INT, 32'd0}))
                end else `RITE_ERR
              // gpio.c: GPIO_set_dir。IN は入力、OUT は出力、ほか (HIGH_Z) は何もしない
              F_SET_DIR_AT:
                if (n_args == 4'd2 && v1.tag == T_INT && v2.tag == T_INT) begin
                  gpio_we <= (v1.val < 32'd32) && (v2.val == FLAG_IN || v2.val == FLAG_OUT); gpio_pin <= v1.val[4:0];
                  gpio_set_out <= 1'b0; gpio_set_dir <= 1'b1; gpio_dir_v <= (v2.val == FLAG_OUT);
                  `RITE_WA(value_t'({T_INT, 32'd0}))
                end else `RITE_ERR
              // gpio.c: mrb_write。0 と 1 だけ。pin は @pin
              F_WRITE:
                if (n_args == 4'd1 && recv.tag == T_OBJ && v1.tag == T_INT && (v1.val == 32'd0 || v1.val == 32'd1))
                  `RITE_IV(recv.val[3:0], N_AT_PIN, 1'b0, NIL_V, S_WRITE2)
                else `RITE_ERR
              F_SLEEP_MS:
                if (n_args == 4'd1 && v1.tag == T_INT && !v1.val[31]) begin
                  wake_ms <= ms_now + v1.val;
                  `RITE_WA(NIL_V)
                  st <= S_SLEEP;
                end else `RITE_ERR
              // module_function(sym): 探して、特異クラスに public で写し、元の行を private にする
              F_MODFUNC:
                if (n_args == 4'd1 && recv.tag == T_CLASS && recv_flags[0] && v1.tag == T_SYM)
                  `RITE_MLOOK(recv.val[CW-1:0], v1.val[SW-1:0], S_MF2)
                else `RITE_ERR
              // attr_reader(sym): 読み手のメソッドを置く (呼ぶのは R4 で)
              F_ATTR_READER:
                if (n_args == 4'd1 && recv.tag == T_CLASS && v1.tag == T_SYM)
                  `RITE_MDEF(recv.val[CW-1:0], v1.val[SW-1:0], K_ATTR, v1.val[7:0], 1'b0, S_SYMRET)
                else `RITE_ERR
              F_AND:    if (n_args == 4'd1 && recv.tag == T_INT && v1.tag == T_INT) `RITE_WA(value_t'({T_INT, recv.val & v1.val})) else `RITE_ERR
              F_OR:     if (n_args == 4'd1 && recv.tag == T_INT && v1.tag == T_INT) `RITE_WA(value_t'({T_INT, recv.val | v1.val})) else `RITE_ERR
              // 右へずらす (負のずらしは範囲の外)。1 cycle に 1 bit (S_SHR)。32 以上は 31 と同じ (符号で埋まる)
              F_RSHIFT: if (n_args == 4'd1 && recv.tag == T_INT && v1.tag == T_INT && !v1.val[31]) begin
                          tv <= {T_INT, recv.val}; shn <= (v1.val > 32'd31) ? 5'd31 : v1.val[4:0]; st <= S_SHR;
                        end else `RITE_ERR
              F_EQQ:    if (n_args == 4'd1) `RITE_WA(bool_v(eq01)) else `RITE_ERR
              F_NOT:    if (n_args == 4'd0) `RITE_WA(bool_v(!truthy_f(recv.tag))) else `RITE_ERR
              default: `RITE_ERR
            endcase
          end
          // Class#new: initialize が irep なら、object を self にして呼び、返す値は object (retself)
          S_NEW2: begin
            st <= S_OP;
            if (!lk_found) `RITE_ERR
            else if (lk_kind == K_CFUNC && FW'(lk_tgt) == F_DO_NOTHING) `RITE_WA(value_t'({T_OBJ, 28'd0, newobj}))
            else if (lk_kind == K_IREP) begin
              c_irep <= lk_tgt[IW-1:0]; c_base <= abs_a; c_tc <= lk_owner; c_env <= '0; c_isblk <= 1'b0; c_argc <= n_args;
              c_self <= 2'd1; cself <= {T_OBJ, 28'd0, newobj}; c_nil <= 1'b1; c_retself <= 1'b1; c_top <= 1'b0;
              nil_idx <= abs_a[RW-1:0] + RW'(n_args) + RW'(1);
              c_clr <= 5'(n_args) + 5'd2; st <= S_CALL;
            end else `RITE_ERR
          end
          S_WRITE2: begin
            st <= S_OP;
            if (tv.tag != T_INT) `RITE_ERR
            else begin
              gpio_we <= (tv.val < 32'd32); gpio_pin <= tv.val[4:0]; gpio_set_out <= 1'b1; gpio_out_v <= v1.val[0];
              gpio_set_dir <= 1'b0;
              `RITE_WA(value_t'({T_INT, 32'd0}))
            end
          end
          S_MF2: begin
            if (!lk_found) `RITE_ERR
            else begin
              mt_we <= 1'b1; mt_wa <= lk_idx; mt_wd <= {lk_owner, lk_mid, 1'b1, lk_kind, lk_tgt};
              cl_ra <= recv.val[CW-1:0]; rd_wait <= 1'b1; st <= S_MF3;
            end
          end
          S_MF3: if (cl_q.scls == '0) `RITE_ERR else `RITE_MDEF(cl_q.scls, lk_mid, lk_kind, lk_tgt, 1'b0, S_MF4)
          S_MF4: begin st <= S_OP; `RITE_WA(recv) end
          // TDEF / SDEF は名前の sym、attr_reader (SSEND から) は nil
          S_SYMRET: begin st <= S_OP; `RITE_WA((op == OP_SSEND) ? value_t'(NIL_V) : value_t'({T_SYM, 24'd0, bsym})) end
          // CLASS: 定数があれば開き直す (superclass が渡されていれば同じこと)。無ければクラスと特異クラスを作る
          S_CLS2: begin
            if (cm_found) begin
              if (tv.tag != T_CLASS) `RITE_ERR
              else if (nc_sup == '0) begin st <= S_OP; `RITE_WA(tv) end
              else begin cl_ra <= tv.val[CW-1:0]; rd_wait <= 1'b1; st <= S_CLS3; end
            end else if (cls_n + 6'd2 > 6'(NCLS)) `RITE_ERR
            else begin cl_ra <= (nc_sup == '0) ? C_OBJECT : nc_sup; rd_wait <= 1'b1; st <= S_CLS4; end
          end
          S_CLS3: begin st <= S_OP; if (cl_q.sup != nc_sup) `RITE_ERR else `RITE_WA(tv) end
          S_CLS4: begin
            if (cl_q.scls == '0) `RITE_ERR
            else begin
              cl_we <= 1'b1; cl_wa <= cls_n[CW-1:0];
              cl_wd <= {(nc_sup == '0) ? C_OBJECT : nc_sup, cls_n[CW-1:0], CW'(cls_n + 6'd1), nc_base, 3'd0, bsym};
              nc_sup <= cl_q.scls; st <= S_CLS5;
            end
          end
          S_CLS5: begin
            cl_we <= 1'b1; cl_wa <= CW'(cls_n + 6'd1);
            cl_wd <= {nc_sup, CW'(cls_n + 6'd1), CW'(0), CW'(0), 3'd2, SW'(0)};
            cls_n <= cls_n + 6'd2;
            `RITE_CSET(nc_base, bsym, value_t'({T_CLASS, 27'd0, cls_n[CW-1:0]}), S_CLS6)
          end
          S_CLS6: begin st <= S_OP; `RITE_WA(tv) end
          S_MOD2: begin st <= S_OP; if (!cm_found || tv.tag != T_CLASS) `RITE_ERR else `RITE_WA(tv) end
          S_SDEF2: if (cl_q.scls == '0) `RITE_ERR else `RITE_MDEF(cl_q.scls, bsym, K_IREP, 8'(rpid), 1'b0, S_SYMRET)
          S_CGET2: begin st <= S_OP; if (!cm_found) `RITE_ERR else `RITE_WA(tv) end
          S_IVGET2: begin st <= S_OP; `RITE_WA(tv) end
          // ENTER: ブロックを移し、省略された引数の分だけ飛ばす
          S_ENT2: begin
            `RITE_WREG(cur_base + RW'(as_m1) + RW'(as_o) + RW'(1), r_q)
            if (5'(cur_argc) > as_m1) `RITE_NEXT(jmp_to)
            st <= S_OP;
          end

          // cipush: 今の枠を積み、呼ぶ irep の窓へ移る。窓が 64 本を超えるか、枠が 8 段を超えると範囲の外
          S_CALL: begin ir_ra <= c_irep; rd_wait <= 1'b1; st <= S_CALL2; end
          S_CALL2: begin
            if (c_base + 7'(ir_q.nregs) > 7'd64 || sp == 4'(NCI)) `RITE_ERR
            else begin
              // S_START (一番上の枠) は積まない
              ci_we <= !c_top; ci_wa <= sp[2:0];
              ci_wd <= {cur_irep, ptr, cur_base, cur_env, cur_tc, cur_argc, cur_isblk, cur_retself};
              if (!c_top) sp <= sp + 4'd1;
              cur_irep <= c_irep; cur_base <= c_base[RW-1:0]; cur_env <= c_env; cur_tc <= c_tc; cur_argc <= c_argc;
              cur_isblk <= c_isblk; cur_retself <= c_retself;
              `RITE_NEXT(ir_q.iseq)
              clr_i <= c_base + 7'(c_clr); clr_end <= c_base + 7'(ir_q.nregs);
              st <= (c_self == 2'd2) ? S_PRS0 : (c_self == 2'd1) ? S_PWS : c_nil ? S_PWN : S_CLR;
            end
          end
          // ブロックの self: env の R0 を読む
          S_PRS0: begin r_ra <= c_env; rd_wait <= 1'b1; st <= S_PRS2; end
          S_PRS2: begin cself <= r_q; st <= S_PWS; end
          S_PWS: begin `RITE_WREG(cur_base, cself) st <= c_nil ? S_PWN : S_CLR; end
          S_PWN: begin `RITE_WREG(nil_idx, NIL_V) st <= S_CLR; end
          // 今の irep の表と self を読む
          S_FRAME: begin ir_ra <= cur_irep; r_ra <= cur_base; rd_wait <= 1'b1; st <= S_FRAME2; end
          S_FRAME2: begin
            cur_symb <= ir_q.symb; cur_nsym <= ir_q.nsym; cur_repb <= ir_q.repb; cur_rlen <= ir_q.rlen;
            cur_self <= r_q;
            `RITE_NEXT(ptr)
            st <= S_OP;
          end
          // cipop
          S_RET2: begin
            sp <= sp - 4'd1;
            cur_irep <= ci_q.irep; cur_base <= ci_q.base; cur_env <= ci_q.env; cur_tc <= ci_q.tc; cur_argc <= ci_q.argc;
            cur_isblk <= ci_q.isblk; cur_retself <= ci_q.retself;
            ptr <= ci_q.pc;
            st <= S_FRAME;
          end

          // ---- メソッドの探索 (class.c mrb_method_search_vm、cache 無し) ----
          S_ML0: begin
            if (lk_c == '0) begin lk_found <= 1'b0; st <= lk_ret; end
            else begin cl_ra <= lk_c; rd_wait <= 1'b1; st <= S_ML1; end
          end
          S_ML1: begin
            lk_mtc <= cl_q.mtc; lk_sup <= cl_q.sup;
            if (mt_n == 7'd0) begin lk_c <= cl_q.sup; st <= S_ML0; end
            else begin mj <= '0; mt_ra <= '0; rd_wait <= 1'b1; st <= S_ML2; end
          end
          S_ML2: begin
            if (mt_q.cls == lk_mtc && mt_q.mid == lk_mid) begin
              lk_found <= 1'b1; lk_priv <= mt_q.priv; lk_kind <= mt_q.kind; lk_tgt <= mt_q.tgt; lk_idx <= mj;
              lk_owner <= lk_mtc; st <= lk_ret;
            end else if (7'(mj) + 7'd1 == mt_n) begin lk_c <= lk_sup; st <= S_ML0; end
            else begin mj <= mj + 6'd1; mt_ra <= mj + 6'd1; rd_wait <= 1'b1; end
          end
          // ---- メソッドの定義 (class.c mrb_define_method_raw: 同じクラスと名前の行は置き換える) ----
          S_MD0: begin
            if (mt_n == 7'd0) begin mj <= '0; st <= S_MD1; end
            else begin mj <= '0; mt_ra <= '0; rd_wait <= 1'b1; st <= S_MD1; end
          end
          S_MD1: begin
            if (mt_n != 7'd0 && mt_q.cls == md.cls && mt_q.mid == md.mid) begin
              mt_we <= 1'b1; mt_wa <= mj; mt_wd <= md; st <= md_ret;
            end else if (mt_n == 7'd0 || 7'(mj) + 7'd1 == mt_n) begin
              if (mt_n == 7'(NMT)) `RITE_ERR
              else begin mt_we <= 1'b1; mt_wa <= mt_n[5:0]; mt_wd <= md; mt_n <= mt_n + 7'd1; st <= md_ret; end
            end else begin mj <= mj + 6'd1; mt_ra <= mj + 6'd1; rd_wait <= 1'b1; end
          end
          // ---- 定数 (variable.c の mrb_vm_const_get / mrb_const_set) ----
          // cm_c のクラスの行を探す。無ければ次のクラス (mode 0: 外側、終われば superclass、mode 1: superclass、mode 2: 終わり)
          S_CL0: begin
            if (cm_c == '0) begin
              if (cm_lex) begin cm_lex <= 1'b0; cm_c <= cm_start; end
              else if (cm_set) begin   // mrb_const_set: 無ければ足す
                if (co_n == 6'(NCONST)) `RITE_ERR
                else begin co_we <= 1'b1; co_wa <= co_n[4:0]; co_wd <= {cm_start, cm_sym, tv}; co_n <= co_n + 6'd1; st <= cm_ret; end
              end else begin cm_found <= 1'b0; st <= cm_ret; end
            end else begin cl_ra <= cm_c; rd_wait <= 1'b1; st <= S_CL1; end
          end
          S_CL1: begin
            cm_key <= cm_lex ? cm_c : cl_q.mtc;
            cm_next <= (cm_mode == 2'd2) ? '0 : cm_lex ? cl_q.outer : cl_q.sup;
            if (co_n == 6'd0) begin cm_c <= (cm_mode == 2'd2) ? '0 : cm_lex ? cl_q.outer : cl_q.sup; st <= S_CL0; end
            else begin cj <= '0; co_ra <= '0; rd_wait <= 1'b1; st <= S_CL2; end
          end
          S_CL2: begin
            if (co_q.cls == cm_key && co_q.sym == cm_sym) begin
              cm_found <= 1'b1;
              if (cm_set) begin co_we <= 1'b1; co_wa <= cj; co_wd <= {cm_start, cm_sym, tv}; end
              else tv <= co_q.v;
              st <= cm_ret;
            end else if (6'(cj) + 6'd1 == co_n) begin cm_c <= cm_next; st <= S_CL0; end
            else begin cj <= cj + 5'd1; co_ra <= cj + 5'd1; rd_wait <= 1'b1; end
          end
          // ---- ivar (variable.c の mrb_iv_get / mrb_iv_set) ----
          S_IVS0: begin
            if (iv_n == 6'd0) begin
              if (iv_set) begin iv_we <= 1'b1; iv_wa <= '0; iv_n <= 6'd1; end
              else tv <= NIL_V;
              st <= iv_ret;
            end else begin vj <= '0; iv_ra <= '0; rd_wait <= 1'b1; st <= S_IVS1; end
          end
          S_IVS1: begin
            if (iv_q.obj == iv_o && iv_q.sym == iv_s) begin
              if (iv_set) begin iv_we <= 1'b1; iv_wa <= vj; end
              else tv <= iv_q.v;
              st <= iv_ret;
            end else if (6'(vj) + 6'd1 == iv_n) begin
              if (!iv_set) begin tv <= NIL_V; st <= iv_ret; end
              else if (iv_n == 6'(NIV)) `RITE_ERR
              else begin iv_we <= 1'b1; iv_wa <= iv_n[4:0]; iv_n <= iv_n + 6'd1; st <= iv_ret; end
            end else begin vj <= vj + 5'd1; iv_ra <= vj + 5'd1; rd_wait <= 1'b1; end
          end

          S_SHR: begin
            if (shn == 5'd0) begin st <= S_OP; `RITE_WA(tv) end
            else begin tv.val <= {tv.val[31], tv.val[31:1]}; shn <= shn - 5'd1; end
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
`undef RITE_WREG
`undef RITE_WA
`undef RITE_MLOOK
`undef RITE_MDEF
`undef RITE_CLOOK
`undef RITE_CSET
`undef RITE_IV
endmodule
