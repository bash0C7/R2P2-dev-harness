// mruby バイトコード (RITE0400) を直接実行する CPU コア。多サイクル、1命令は FETCH -> EXEC の 2 cycle が基本で、
// ヒープを触る命令・呼び出し・GC・sleep はマイクロ状態で数 cycle かける。
//
// ROM は tools/fpga/rom.rb (PicoRuby の変換器) が作る 48bit 固定長語 ({op, a, b, c})。命令の意味は
// tools/fpga/ref_vm.rb と同じ (docs/spec.md §10)。ずれたら rake fpga:check / fpga:fuzz が落ちる。
//
// 値 = {tag[2:0], value[31:0]}。ARRAY / PROC はヒープ (HEAP_SIZE 語、半分ずつ使う) の語アドレス。
// レジスタはレジスタ窓: R[i] はレジスタファイルの bp + i。呼び出し先の bp は呼び出し元の bp + a。
// cp は今のフレームが Proc (ブロック) の時のその参照。外側の変数は Proc の連鎖でたどる。
//
// en が 0 の cycle は何も進まない (CPU を遅く回すためのクロックイネーブル)。ms_tick は 1ms ごとの 1 cycle のパルスで、
// sleep_ms / sleep だけが使う (en に関係なく数える)。
`timescale 1ns / 1ps
// 値を tag / value / アドレス / 長さに切り分けて使うので、どの bit も使わない所が必ず出る。未使用の lint はこの file だけ切る
/* verilator lint_off UNUSEDSIGNAL */
module mrb_core
  import mrb_pkg::*;
#(
  parameter int NREGS   = RF_SIZE, // レジスタファイルの大きさ (全フレームで共有)
  parameter int PC_BITS = 10
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                en,
  input  logic                ms_tick,

  // ROM (同期読み出し: rom_addr を出した次の cycle に rom_data)
  output logic [PC_BITS-1:0]  rom_addr,
  input  logic [47:0]         rom_data,

  // I/O (読み出しは組み合わせ)
  output logic [7:0]          io_addr,
  input  logic [VAL_BITS-1:0] io_rdata,
  output logic                io_we,
  output logic [VAL_BITS-1:0] io_wdata,

  output logic                halted,
  output logic                error,

  // トレース用: retire は命令を実行し始めた cycle (X 行)。rf_we はレジスタに書く cycle (W 行)
  output logic                retire,
  output logic [PC_BITS-1:0]  dbg_pc,
  output logic [7:0]          dbg_op,
  output logic                rf_we,
  output logic [7:0]          rf_waddr,
  output logic [VAL_BITS-1:0] rf_wdata
);
  localparam int RB   = $clog2(NREGS);
  localparam int SB   = $clog2(STACK_DEPTH + 1);
  localparam int CB   = $clog2(NCONST);
  localparam int HB   = $clog2(HEAP_SIZE);
  localparam int HALF = HEAP_SIZE / 2;
  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};
  localparam logic signed [INT_BITS-1:0] INT_MIN = {1'b1, {(INT_BITS-1){1'b0}}};

  typedef enum logic [4:0] {
    S_INIT, S_FETCH, S_EXEC, S_CLEAR, S_HALT, S_ERROR,
    S_ALLOC,              // 確保 (足りなければ GC してもう一度)
    S_GC_ROOT, S_GC_SCAN, // GC: ルートを写す / 写した先を走査する
    S_FWD,                // GC: オブジェクトを1語ずつ写す
    S_BLOCK,              // Proc を書く
    S_AHDR, S_AELEM,      // 配列リテラル: 見出し / 要素
    S_SET1, S_GROW, S_FILL, S_PUT, // 配列への代入・push
    S_INCL,               // include?
    S_UNWIND, S_UNWIND_RET, // break (動的) / ブロックの中の return
    S_SLEEP,
    S_WALK, S_UPOP        // Proc の連鎖をたどって外側のフレームの底を求め、命令を仕上げる
  } state_t;
  state_t state;

  // 確保のあとに続ける処理
  typedef enum logic [1:0] { MO_BLOCK, MO_ARRAY, MO_GROW } mop_t;
  mop_t mop;

  logic [PC_BITS-1:0]  pc;
  logic [VAL_BITS-1:0] regs [NREGS];
  logic [RB-1:0]       bp;
  logic [7:0]          argc;
  logic [VAL_BITS-1:0] cp;

  // コールスタック: 戻り先の pc、呼び出し元の bp と Proc
  logic [PC_BITS-1:0]  ret_pc [STACK_DEPTH];
  logic [RB-1:0]       ret_bp [STACK_DEPTH];
  logic [VAL_BITS-1:0] ret_cp [STACK_DEPTH];
  logic [SB-1:0]       sp;

  logic [SB-2:0] top;
  assign top = (SB-1)'(sp - SB'(1));

  // 定数 (GETCONST / SETCONST)
  logic [VAL_BITS-1:0] consts [NCONST];
  logic [NCONST-1:0]   cvalid;

  // ヒープ
  logic [VAL_BITS-1:0] heap [HEAP_SIZE];
  logic                space;     // 使っている半分
  logic [HB:0]         hp;        // 次に確保する語
  logic [HB:0]         need;      // 確保する語数
  logic [HB:0]         p_new;     // 確保した先頭
  logic                gc_done;   // この確保で GC を済ませたか

  // GC
  logic [2:0]          gphase;    // 0 レジスタ、1 定数、2 スタックの Proc、3 cp、4 走査
  logic [7:0]          gi;
  logic [HB:0]         gfree, scan;
  logic [HB:0]         fw_src, fw_k, fw_size;
  logic [TAG_BITS-1:0] fw_tag;

  // マイクロ状態の作業
  logic [RB:0]         clr_ptr, clr_end;
  logic [RB:0]         m_dst, m_src, m_arr, m_val;
  logic [7:0]          m_n;
  logic [HB:0]         m_k;
  logic [15:0]         m_i, m_len, m_cap;
  logic                m_push, m_found;
  logic [VAL_BITS-1:0] hold;
  logic [RB-1:0]       target;
  logic [41:0]         remain;

  // ---- 値の部品
  function automatic logic [TAG_BITS-1:0] tag_of(input logic [VAL_BITS-1:0] v);
    return v[VAL_BITS-1 -: TAG_BITS];
  endfunction
  function automatic logic [INT_BITS-1:0] val_of(input logic [VAL_BITS-1:0] v);
    return v[INT_BITS-1:0];
  endfunction
  function automatic logic is_ref(input logic [VAL_BITS-1:0] v);
    return tag_of(v) == TAG_ARRAY || tag_of(v) == TAG_PROC;
  endfunction
  function automatic logic [VAL_BITS-1:0] mk_int(input logic [INT_BITS-1:0] v);
    return {TAG_INT, v};
  endfunction
  function automatic logic [VAL_BITS-1:0] mk_bool(input logic t);
    return {t ? TAG_TRUE : TAG_FALSE, {INT_BITS{1'b0}}};
  endfunction
  function automatic logic [VAL_BITS-1:0] mk(input logic [TAG_BITS-1:0] t, input logic [INT_BITS-1:0] v);
    return {t, v};
  endfunction
  function automatic logic [15:0] lo16(input logic [VAL_BITS-1:0] v); // 長さ・容量・語数
    return v[15:0];
  endfunction
  function automatic logic [HB-1:0] ha(input logic [INT_BITS-1:0] v); // ヒープの語アドレス
    return v[HB-1:0];
  endfunction

  // == : Integer は値、参照は同じものか、それ以外は型。配列同士はエラー (eq_err)
  function automatic logic eq_of(input logic [VAL_BITS-1:0] x, input logic [VAL_BITS-1:0] y);
    if (tag_of(x) != tag_of(y)) return 1'b0;
    if (tag_of(x) == TAG_INT || is_ref(x)) return val_of(x) == val_of(y);
    return 1'b1;
  endfunction

  // ---- decode
  logic [7:0]  op, a;
  logic [15:0] b, c;
  assign op = rom_data[47:40];
  assign a  = rom_data[39:32];
  assign b  = rom_data[31:16];
  assign c  = rom_data[15:0];

  // レジスタファイルでの番号と、範囲に収まっているか (ref_vm.rb の ok?)
  logic [16:0] ia, ia1, ia2, ib;
  assign ia  = 17'(bp) + 17'(a);
  assign ia1 = ia + 17'd1;
  assign ia2 = ia + 17'd2;
  assign ib  = 17'(bp) + 17'(b);

  logic a_ok, a1_ok, a2_ok, b_ok;
  assign a_ok  = ia  < 17'(NREGS);
  assign a1_ok = ia1 < 17'(NREGS);
  assign a2_ok = ia2 < 17'(NREGS);
  assign b_ok  = ib  < 17'(NREGS);

  logic [VAL_BITS-1:0] ra, ra1, rb;
  assign ra  = regs[ia[RB-1:0]];
  assign ra1 = regs[ia1[RB-1:0]];
  assign rb  = regs[ib[RB-1:0]];

  logic ra_int, ra1_int, ra_truthy, ra_ary, ra1_ary;
  assign ra_int    = tag_of(ra) == TAG_INT;
  assign ra1_int   = tag_of(ra1) == TAG_INT;
  assign ra_ary    = tag_of(ra) == TAG_ARRAY;
  assign ra1_ary   = tag_of(ra1) == TAG_ARRAY;
  assign ra_truthy = tag_of(ra) != TAG_NIL && tag_of(ra) != TAG_FALSE;

  logic signed [INT_BITS-1:0] x, y;
  assign x = val_of(ra);
  assign y = val_of(ra1);

  logic eq, eq_err;
  assign eq     = eq_of(ra, ra1);
  assign eq_err = ra_ary && ra1_ary;

  // Ruby の / と % (floor 側に丸める)。y = 0 は呼ぶ側でエラーにする。INT_MIN / -1 は折り返す
  logic signed [INT_BITS-1:0] q_trunc, r_trunc, q_floor, r_floor;
  always_comb begin
    if (y == 0 || (x == INT_MIN && y == -1)) begin
      q_trunc = (y == 0) ? '0 : INT_MIN;
      r_trunc = '0;
    end else begin
      q_trunc = x / y;
      r_trunc = x % y;
    end
    q_floor = (r_trunc != 0 && ((r_trunc < 0) != (y < 0))) ? q_trunc - 1 : q_trunc;
    r_floor = (r_trunc != 0 && ((r_trunc < 0) != (y < 0))) ? r_trunc + y : r_trunc;
  end

  // x << s (s が負なら算術右シフト)。32 以上ずらすと 0 か符号
  function automatic logic [INT_BITS-1:0] shift(input logic signed [INT_BITS-1:0] v,
                                                input logic signed [INT_BITS:0] s);
    if (s >= (INT_BITS+1)'(INT_BITS)) return '0;
    if (s <= -(INT_BITS+1)'(INT_BITS)) return v < 0 ? '1 : '0;
    if (s >= 0) return v << s[5:0];
    return v >>> (-s);
  endfunction

  // ---- 配列 (R[a] が配列の時): 長さ、中身、容量
  logic [HB-1:0] arr_p, arr_d;
  logic [15:0]   arr_len;
  assign arr_p   = ha(val_of(ra));
  assign arr_len = lo16(heap[arr_p + HB'(1)]);
  assign arr_d   = ha(val_of(heap[arr_p + HB'(2)]));

  // 添字 (GETIDX / SETIDX): 負なら後ろから
  logic signed [INT_BITS-1:0] idx_raw, idx_adj;
  logic [VAL_BITS-1:0]        idx_recv;
  logic [HB-1:0]              idx_p, idx_d;
  logic [15:0]                idx_len;
  always_comb begin
    idx_recv = op == OP_GETIDX0 ? rb : ra;
    idx_raw  = op == OP_GETIDX0 ? '0 : y;
    idx_p    = ha(val_of(idx_recv));
    idx_len  = lo16(heap[idx_p + HB'(1)]);
    idx_d    = ha(val_of(heap[idx_p + HB'(2)]));
    idx_adj  = idx_raw < 0 ? idx_raw + INT_BITS'(idx_len) : idx_raw;
  end
  logic [VAL_BITS-1:0] idx_val;
  assign idx_val = (idx_adj >= 0 && idx_adj < INT_BITS'(idx_len)) ? heap[idx_d + HB'(1) + ha(idx_adj)] : V_NIL;

  // 深さ k のフレームの底 (0 は今のフレーム、1 は今の Proc を作ったフレーム、2 はその外側 ...) は、
  // S_WALK で Proc の連鎖を 1 cycle に1段ずつたどって求める (k = 0 は EXEC でそのまま bp)
  logic [3:0]    fb_k;
  logic          fb_now;     // EXEC で決まる (k = 0)
  assign fb_k   = (op == OP_BREAK) ? 4'd1 : c[3:0];
  assign fb_now = fb_k == 4'd0;
  logic [VAL_BITS-1:0] walk_p;
  logic [3:0]          walk_left;
  logic [RB-1:0]       fb_base;  // S_UPOP での底
  logic [16:0]         iu;       // S_UPOP / EXEC での外側のレジスタの番号
  logic                u_ok;
  assign iu   = (state == S_UPOP ? 17'(fb_base) : 17'(bp)) + 17'(b);
  assign u_ok = iu < 17'(NREGS);

  // ---- Proc (R[a] が Proc の時): 先頭 pc、引数の数、nregs
  logic [HB-1:0]  pr_p;
  logic [31:0]    pr_info;
  assign pr_p    = ha(val_of(ra));
  assign pr_info = val_of(heap[pr_p + HB'(1)]);

  // ---- 呼び出し (SSEND / SSEND0 / BLKCALL)
  logic [7:0]  call_nregs, call_keep;
  logic [RB:0] call_bp, call_clr_from, call_clr_to;
  logic [7:0]  call_need;
  always_comb begin
    if (op == OP_BLKCALL) begin
      call_nregs = pr_info[31:24];
      call_keep  = b[7:0] < pr_info[23:16] ? b[7:0] : pr_info[23:16];
    end else begin
      call_nregs = c[15:8];
      call_keep  = {1'b0, c[6:0]} + (c[7] ? 8'd1 : 8'd0); // ブロックを渡すならその枠を残す
    end
    call_need = call_nregs > call_keep ? call_nregs : call_keep + 8'd1;
  end
  assign call_bp       = {1'b0, ia[RB-1:0]};
  assign call_clr_from = call_bp + (RB+1)'(call_keep) + (RB+1)'(1);
  assign call_clr_to   = call_bp + (RB+1)'(call_nregs);

  // ---- execute (組み合わせ)
  logic                wr;          // R[a] に wval を書く
  logic [VAL_BITS-1:0] wval;
  logic                iow;
  logic [PC_BITS-1:0]  npc;
  logic                halt, err;
  logic                do_call, do_ret, set_const, set_up, pop_len;
  logic                go_block, go_array, go_set, go_incl, go_unwind, go_unwind_ret, go_sleep, go_walk;

  assign io_addr  = b[7:0];
  assign io_wdata = ra;

  always_comb begin
    wr        = 1'b0;
    wval      = V_NIL;
    iow       = 1'b0;
    npc       = pc + PC_BITS'(1);
    halt      = 1'b0;
    err       = 1'b0;
    do_call   = 1'b0;
    do_ret    = 1'b0;
    set_const = 1'b0;
    set_up    = 1'b0;
    pop_len   = 1'b0;
    go_block  = 1'b0;
    go_array  = 1'b0;
    go_set    = 1'b0;
    go_incl   = 1'b0;
    go_unwind = 1'b0;
    go_unwind_ret = 1'b0;
    go_sleep  = 1'b0;
    go_walk   = 1'b0;

    case (op)
      OP_NOP: ;
      OP_MOVE:      begin wr = 1'b1; wval = rb; err = !b_ok; end
      OP_LOADI8:    begin wr = 1'b1; wval = mk_int({24'd0, b[7:0]}); end
      OP_LOADINEG:  begin wr = 1'b1; wval = mk_int(-{24'd0, b[7:0]}); end
      OP_LOADI__1:  begin wr = 1'b1; wval = mk_int(-32'sd1); end
      OP_LOADI_0, OP_LOADI_1, OP_LOADI_2, OP_LOADI_3,
      OP_LOADI_4, OP_LOADI_5, OP_LOADI_6, OP_LOADI_7:
                    begin wr = 1'b1; wval = mk_int({24'd0, op - OP_LOADI_0}); end
      OP_LOADI16:   begin wr = 1'b1; wval = mk_int({{16{b[15]}}, b}); end
      OP_LOADI32:   begin wr = 1'b1; wval = mk_int({b, c}); end
      OP_LOADNIL, OP_TDEF: begin wr = 1'b1; wval = V_NIL; end
      OP_LOADTRUE:  begin wr = 1'b1; wval = mk_bool(1'b1); end
      OP_LOADFALSE: begin wr = 1'b1; wval = mk_bool(1'b0); end
      OP_GETGV:     begin wr = 1'b1; wval = io_rdata; err = b[7:0] >= 8'(NPORTS); end
      // 配列や Proc はピンに出せない
      OP_SETGV:     begin iow = 1'b1; err = b[7:0] >= 8'(NPORTS) || is_ref(ra); end
      OP_GETCONST: begin
        wr   = 1'b1;
        wval = consts[b[CB-1:0]];
        err  = b >= 16'(NCONST) || !cvalid[b[CB-1:0]];
      end
      OP_SETCONST: begin set_const = 1'b1; err = b >= 16'(NCONST); end
      OP_JMP:       npc = b[PC_BITS-1:0];
      OP_JMPIF:     if (ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNOT:    if (!ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNIL:    if (tag_of(ra) == TAG_NIL) npc = b[PC_BITS-1:0];
      OP_EQ:        begin wr = 1'b1; err = !a1_ok || eq_err; wval = mk_bool(eq); end
      OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_LT, OP_LE, OP_GT, OP_GE: begin
        wr  = 1'b1;
        err = !a1_ok || !(ra_int && ra1_int) || (op == OP_DIV && y == 0);
        case (op)
          OP_ADD:  wval = mk_int(x + y);
          OP_SUB:  wval = mk_int(x - y);
          OP_MUL:  wval = mk_int(x * y);
          OP_DIV:  wval = mk_int(q_floor);
          OP_LT:   wval = mk_bool(x < y);
          OP_LE:   wval = mk_bool(x <= y);
          OP_GT:   wval = mk_bool(x > y);
          default: wval = mk_bool(x >= y);
        endcase
      end
      OP_ADDI:   begin wr = 1'b1; err = !ra_int; wval = mk_int(x + {24'd0, b[7:0]}); end
      OP_SUBI:   begin wr = 1'b1; err = !ra_int; wval = mk_int(x - {24'd0, b[7:0]}); end
      OP_ADDILV: begin wr = 1'b1; err = !ra_int; wval = mk_int(x + {24'd0, c[7:0]}); end
      OP_SUBILV: begin wr = 1'b1; err = !ra_int; wval = mk_int(x - {24'd0, c[7:0]}); end
      OP_SEND, OP_SEND0: begin
        wr = 1'b1;
        // 組み込みメソッドの番号と引数の数が合っていること
        if (b >= 16'(NBUILTIN) || c != {15'd0, BI_ARGC1[b[4:0]]}) err = 1'b1;
        else if (c == 16'd1 && !a1_ok) err = 1'b1;
        else if (ra_ary) begin
          case (b[7:0])
            BI_SIZE, BI_LENGTH: wval = mk_int({16'd0, arr_len});
            BI_EMPTY: wval = mk_bool(arr_len == 0);
            BI_FIRST: wval = arr_len == 0 ? V_NIL : heap[arr_d + HB'(1)];
            BI_LAST:  wval = arr_len == 0 ? V_NIL : heap[arr_d + HB'(arr_len)];
            BI_POP: begin
              wval    = arr_len == 0 ? V_NIL : heap[arr_d + HB'(arr_len)];
              pop_len = arr_len != 0;
            end
            BI_PUSH, BI_SHL: begin wr = 1'b0; go_set = 1'b1; err = arr_len >= 16'hFFFF; end
            BI_INCL: begin wr = 1'b0; go_incl = 1'b1; err = ra1_ary; end
            BI_NOT: wval = mk_bool(1'b0);
            BI_NEQ: begin wval = mk_bool(!eq); err = eq_err; end
            default: err = 1'b1;
          endcase
        end
        else if (b[7:0] == BI_NOT) wval = mk_bool(!ra_truthy);
        else if (b[7:0] == BI_NEQ) begin wval = mk_bool(!eq); err = eq_err; end
        else if (b[7:0] == BI_SLEEPMS || b[7:0] == BI_SLEEP) begin
          // 時間を待ってから R[a] = 引数
          wr       = 1'b0;
          err      = !ra1_int || y < 0;
          go_sleep = 1'b1;
        end
        else if (!ra_int || (c == 16'd1 && !ra1_int)) err = 1'b1;
        else begin
          case (b[7:0])
            BI_MOD:  begin err = y == 0; wval = mk_int(r_floor); end
            BI_NEG:  wval = mk_int(-x);
            BI_SHL:  wval = mk_int(shift(x, {y[INT_BITS-1], y}));
            BI_SHR:  wval = mk_int(shift(x, -{y[INT_BITS-1], y}));
            BI_AND:  wval = mk_int(x & y);
            BI_OR:   wval = mk_int(x | y);
            BI_XOR:  wval = mk_int(x ^ y);
            BI_INV:  wval = mk_int(~x);
            BI_ABS:  wval = mk_int(x < 0 ? -x : x);
            BI_ZERO: wval = mk_bool(x == 0);
            BI_EVEN: wval = mk_bool(!x[0]);
            BI_ODD:  wval = mk_bool(x[0]);
            default: err = 1'b1;
          endcase
        end
      end
      OP_SSEND, OP_SSEND0, OP_BLKCALL: begin
        do_call = 1'b1;
        npc     = op == OP_BLKCALL ? pr_info[PC_BITS-1:0] : b[PC_BITS-1:0];
        err     = (17'(ia[RB-1:0]) + 17'(call_need) > 17'(NREGS)) || sp >= SB'(STACK_DEPTH) ||
                  (op == OP_BLKCALL && (tag_of(ra) != TAG_PROC || !(ia + 17'(b[7:0]) < 17'(NREGS))));
      end
      OP_ENTER: err = argc != a;
      OP_RETURN, OP_RETNIL: begin
        if (sp == '0) halt = 1'b1;
        else begin
          do_ret = 1'b1;
          npc    = ret_pc[top];
          wval   = op == OP_RETURN ? ra : V_NIL;
        end
      end
      OP_BREAK: begin
        if (sp == '0) err = 1'b1;
        else if (c == 16'd0) begin
          // iterator に直接渡したブロック: フレームを1つ畳んで出口 (b) へ
          do_ret = 1'b1;
          npc    = b[PC_BITS-1:0];
          wval   = ra;
        end else begin
          // Proc を作ったフレームまで畳む (そのフレームの底を S_WALK で求める)
          go_walk = 1'b1;
        end
      end
      OP_RETURN_BLK: begin
        err = c > 16'd15;
        if (fb_now) go_unwind_ret = 1'b1; else go_walk = 1'b1;
      end
      OP_GETUPVAR, OP_BLKPUSH: begin
        err = c > 16'd15;
        if (fb_now) begin wr = 1'b1; wval = regs[iu[RB-1:0]]; err = !u_ok; end
        else go_walk = 1'b1;
      end
      OP_SETUPVAR: begin
        err = c > 16'd15;
        if (fb_now) begin set_up = 1'b1; wval = ra; err = !u_ok; end
        else go_walk = 1'b1;
      end
      OP_BLOCK:  go_block = 1'b1;
      OP_ARRAY:  begin go_array = 1'b1; err = b[7:0] != 0 && !(ia + 17'(b[7:0]) - 17'd1 < 17'(NREGS)); end
      OP_ARRAY2: begin go_array = 1'b1; err = c[7:0] != 0 && !(17'(bp) + 17'(b[7:0]) + 17'(c[7:0]) - 17'd1 < 17'(NREGS)); end
      OP_GETIDX, OP_GETIDX0: begin
        wr   = 1'b1;
        wval = idx_val;
        err  = (op == OP_GETIDX && !a1_ok) || (op == OP_GETIDX0 && !b_ok) || tag_of(idx_recv) != TAG_ARRAY ||
               (op == OP_GETIDX && !ra1_int);
      end
      OP_SETIDX: begin
        go_set = 1'b1;
        err    = !a2_ok || !ra_ary || !ra1_int || idx_adj < 0 || idx_adj >= 32'sh10000;
      end
      OP_STOP: halt = 1'b1;
      default: err = 1'b1;
    endcase

    // a を使う命令は bp + a がレジスタファイルに収まっていること (ref_vm.rb と同じ判定)
    if (!a_ok && !(op == OP_NOP || op == OP_JMP || op == OP_RETNIL || op == OP_STOP)) err = 1'b1;
    if (err) begin
      wr = 1'b0; iow = 1'b0; halt = 1'b0; do_call = 1'b0; do_ret = 1'b0; set_const = 1'b0; set_up = 1'b0;
      pop_len = 1'b0; go_block = 1'b0; go_array = 1'b0; go_set = 1'b0; go_incl = 1'b0;
      go_unwind = 1'b0; go_unwind_ret = 1'b0; go_sleep = 1'b0; go_walk = 1'b0;
    end
  end

  // ---- マイクロ状態でレジスタに書くもの (トレースにも出す)
  logic                m_we;
  logic [7:0]          m_waddr;
  logic [VAL_BITS-1:0] m_wdata;
  logic [HB-1:0]       s_p, s_d;   // S_SET1 / S_GROW / S_FILL / S_PUT: 配列と中身
  logic [15:0]         s_len;
  assign s_p   = ha(val_of(regs[m_arr[RB-1:0]]));
  assign s_len = lo16(heap[s_p + HB'(1)]);
  assign s_d   = ha(val_of(heap[s_p + HB'(2)]));

  always_comb begin
    m_we    = 1'b0;
    m_waddr = 8'(m_dst);
    m_wdata = V_NIL;
    case (state)
      S_BLOCK: begin m_we = 1'b1; m_wdata = mk(TAG_PROC, 32'(p_new)); end
      S_AELEM: if (m_k == (HB+1)'(m_n)) begin m_we = 1'b1; m_wdata = mk(TAG_ARRAY, 32'(p_new)); end
      S_PUT:   if (m_push) begin m_we = 1'b1; m_wdata = regs[m_arr[RB-1:0]]; end
      S_INCL:  if (m_k == (HB+1)'(m_len) || m_found) begin m_we = 1'b1; m_wdata = mk_bool(m_found); end
      S_UNWIND: if (sp != '0 && ret_bp[top] == target) begin
        m_we = 1'b1; m_waddr = 8'(bp); m_wdata = hold;
      end
      S_UNWIND_RET: if (bp == target && sp != '0) begin
        m_we = 1'b1; m_waddr = 8'(bp); m_wdata = hold;
      end
      S_SLEEP: if (remain == 0) begin m_we = 1'b1; m_wdata = hold; end
      S_UPOP: if (u_ok) begin
        if (op == OP_GETUPVAR || op == OP_BLKPUSH) begin m_we = 1'b1; m_waddr = 8'(ia[RB-1:0]); m_wdata = regs[iu[RB-1:0]]; end
        if (op == OP_SETUPVAR) begin m_we = 1'b1; m_waddr = 8'(iu[RB-1:0]); m_wdata = ra; end
      end
      default: ;
    endcase
  end

  // ---- GC: 今のルート
  logic [VAL_BITS-1:0] root;
  logic                root_live, root_end;
  always_comb begin
    root      = V_NIL;
    root_live = 1'b0;
    root_end  = 1'b0;
    case (gphase)
      3'd0: begin root_end = gi == 8'(NREGS); if (!root_end) begin root = regs[gi[RB-1:0]]; root_live = 1'b1; end end
      3'd1: begin root_end = gi == 8'(NCONST); if (!root_end) begin root = consts[gi[CB-1:0]]; root_live = cvalid[gi[CB-1:0]]; end end
      3'd2: begin root_end = gi == 8'(sp); if (!root_end) begin root = ret_cp[gi[SB-2:0]]; root_live = 1'b1; end end
      default: begin root_end = gi != 0; if (!root_end) begin root = cp; root_live = 1'b1; end end
    endcase
  end
  logic [VAL_BITS-1:0] fw_obj; // 写すものの見出し (転送済みなら FWD)
  logic [VAL_BITS-1:0] fw_in;
  assign fw_in  = gphase == 3'd4 ? heap[scan[HB-1:0]] : root;
  assign fw_obj = heap[ha(val_of(fw_in))];

  // ---- 状態遷移
  wire exec = state == S_EXEC && en;

  assign rom_addr = pc;
  assign retire   = exec;
  assign dbg_pc   = pc;
  assign dbg_op   = op;
  assign rf_we    = (exec && (wr || do_ret || set_up)) || (en && m_we);
  assign rf_waddr = exec ? (do_ret ? 8'(bp) : set_up ? 8'(iu[RB-1:0]) : 8'(ia[RB-1:0])) : m_waddr;
  assign rf_wdata = exec ? wval : m_wdata;
  assign io_we    = exec && iow;
  assign halted   = state == S_HALT;
  assign error    = state == S_ERROR;

  localparam logic [HB:0] HALF_W = (HB+1)'(HALF);
  logic [HB:0] limit;
  assign limit = space ? (HB+1)'(HEAP_SIZE) : HALF_W;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_INIT;
      pc      <= '0;
      bp      <= '0;
      argc    <= '0;
      sp      <= '0;
      cp      <= V_NIL;
      cvalid  <= '0;
      clr_ptr <= '0;
      clr_end <= '0;
      space   <= 1'b0;
      hp      <= '0;
      remain  <= '0;
    end else if (state == S_INIT) begin
      // レジスタファイルは一括ではリセットしない (ブロック RAM にできるように)
      regs[clr_ptr[RB-1:0]] <= V_NIL;
      clr_ptr <= clr_ptr + (RB+1)'(1);
      if (clr_ptr == (RB+1)'(NREGS - 1)) state <= S_FETCH;
    end else begin
      // sleep の残りは en に関係なく 1ms ごとに減らす
      if (state == S_SLEEP && ms_tick && remain != 0) remain <= remain - 42'd1;
      if (en) begin
        if (m_we) regs[m_waddr[RB-1:0]] <= m_wdata;
        case (state)
          S_FETCH: state <= S_EXEC;
          S_EXEC: begin
            if (wr) regs[ia[RB-1:0]] <= wval;
            if (set_up) regs[iu[RB-1:0]] <= ra;
            if (pop_len) heap[arr_p + HB'(1)] <= mk_int({16'd0, arr_len - 16'd1});
            if (set_const) begin
              consts[b[CB-1:0]] <= ra;
              cvalid[b[CB-1:0]] <= 1'b1;
            end
            gc_done <= 1'b0;
            if (err) state <= S_ERROR;
            else if (halt) state <= S_HALT;
            else if (do_call) begin
              ret_pc[sp[SB-2:0]] <= pc + PC_BITS'(1);
              ret_bp[sp[SB-2:0]] <= bp;
              ret_cp[sp[SB-2:0]] <= cp;
              sp                 <= sp + SB'(1);
              regs[ia[RB-1:0]]   <= regs[bp]; // 呼び出し先の R0 = self
              bp                 <= ia[RB-1:0];
              cp                 <= op == OP_BLKCALL ? ra : V_NIL;
              argc               <= {1'b0, c[6:0]};
              clr_ptr            <= call_clr_from;
              clr_end            <= call_clr_to;
              pc                 <= npc;
              state              <= call_clr_from < call_clr_to ? S_CLEAR : S_FETCH;
            end else if (do_ret) begin
              regs[bp] <= wval;
              bp       <= ret_bp[top];
              cp       <= ret_cp[top];
              sp       <= sp - SB'(1);
              pc       <= npc;
              state    <= S_FETCH;
            end else if (go_block) begin
              need  <= (HB+1)'(4);
              mop   <= MO_BLOCK;
              m_dst <= ia[RB:0];
              state <= S_ALLOC;
            end else if (go_array) begin
              m_n   <= op == OP_ARRAY ? b[7:0] : c[7:0];
              m_src <= op == OP_ARRAY ? ia[RB:0] : (RB+1)'(17'(bp) + 17'(b[7:0]));
              need  <= (HB+1)'(4) + (op == OP_ARRAY ? (HB+1)'(b[7:0]) : (HB+1)'(c[7:0]));
              mop   <= MO_ARRAY;
              m_dst <= ia[RB:0];
              state <= S_ALLOC;
            end else if (go_set) begin
              m_arr  <= ia[RB:0];
              m_dst  <= ia[RB:0];
              m_push <= op != OP_SETIDX;
              m_val  <= op == OP_SETIDX ? ia2[RB:0] : ia1[RB:0];
              m_i    <= op == OP_SETIDX ? idx_adj[15:0] : arr_len;
              state  <= S_SET1;
            end else if (go_incl) begin
              m_dst   <= ia[RB:0];
              m_len   <= arr_len;
              m_k     <= '0;
              m_found <= 1'b0;
              hold    <= ra1;
              state   <= S_INCL;
            end else if (go_unwind_ret) begin
              hold   <= ra;
              target <= bp;
              state  <= S_UNWIND_RET;
            end else if (go_walk) begin
              walk_p    <= cp;
              walk_left <= fb_k - 4'd1;
              state     <= S_WALK;
            end else if (go_sleep) begin
              m_dst  <= ia[RB:0];
              hold   <= ra1;
              remain <= b[7:0] == BI_SLEEP ? 42'(unsigned'(y)) * 42'd1000 : 42'(unsigned'(y));
              state  <= S_SLEEP;
            end else begin
              pc    <= npc;
              state <= S_FETCH;
            end
          end
          S_CLEAR: begin
            regs[clr_ptr[RB-1:0]] <= V_NIL;
            clr_ptr <= clr_ptr + (RB+1)'(1);
            if (clr_ptr + (RB+1)'(1) >= clr_end) state <= S_FETCH;
          end

          // ---- 確保: 足りなければ一度だけ GC する
          S_ALLOC: begin
            if (hp + need <= limit) begin
              p_new <= hp;
              hp    <= hp + need;
              m_k   <= '0;
              case (mop)
                MO_BLOCK: state <= S_BLOCK;
                MO_ARRAY: state <= S_AHDR;
                default:  state <= S_GROW;
              endcase
            end else if (!gc_done) begin
              space  <= ~space;
              gfree  <= space ? '0 : HALF_W;
              gphase <= 3'd0;
              gi     <= '0;
              state  <= S_GC_ROOT;
            end else state <= S_ERROR;
          end

          // ---- GC (Cheney)。ref_vm.rb の gc / forward と同じ順
          S_GC_ROOT: begin
            if (root_end) begin
              gi <= '0;
              if (gphase == 3'd3) begin
                gphase <= 3'd4;
                scan   <= space ? HALF_W : '0;
                state  <= S_GC_SCAN;
              end else gphase <= gphase + 3'd1;
            end else if (!root_live || !is_ref(root)) gi <= gi + 8'd1;
            else if (tag_of(fw_obj) == TAG_FWD) begin
              case (gphase)
                3'd0: regs[gi[RB-1:0]] <= mk(tag_of(root), val_of(fw_obj));
                3'd1: consts[gi[CB-1:0]] <= mk(tag_of(root), val_of(fw_obj));
                3'd2: ret_cp[gi[SB-2:0]] <= mk(tag_of(root), val_of(fw_obj));
                default: cp <= mk(tag_of(root), val_of(fw_obj));
              endcase
              gi <= gi + 8'd1;
            end else begin
              fw_src  <= (HB+1)'(ha(val_of(root)));
              fw_size <= (HB+1)'(lo16(fw_obj));
              fw_tag  <= tag_of(root);
              fw_k    <= '0;
              state   <= S_FWD;
            end
          end
          S_GC_SCAN: begin
            if (scan == gfree) begin
              hp      <= gfree;
              gc_done <= 1'b1;
              state   <= S_ALLOC;
            end else if (tag_of(heap[scan[HB-1:0]]) == TAG_HDR || !is_ref(heap[scan[HB-1:0]])) scan <= scan + 1'b1;
            else if (tag_of(fw_obj) == TAG_FWD) begin
              heap[scan[HB-1:0]] <= mk(tag_of(fw_in), val_of(fw_obj));
              scan <= scan + 1'b1;
            end else begin
              fw_src  <= (HB+1)'(ha(val_of(fw_in)));
              fw_size <= (HB+1)'(lo16(fw_obj));
              fw_tag  <= tag_of(fw_in);
              fw_k    <= '0;
              state   <= S_FWD;
            end
          end
          S_FWD: begin
            heap[gfree[HB-1:0] + fw_k[HB-1:0]] <= heap[fw_src[HB-1:0] + fw_k[HB-1:0]];
            fw_k <= fw_k + 1'b1;
            if (fw_k == fw_size) begin
              heap[fw_src[HB-1:0]] <= mk(TAG_FWD, 32'(gfree));
              gfree <= gfree + fw_size + 1'b1;
              case (gphase)
                3'd0: regs[gi[RB-1:0]] <= mk(fw_tag, 32'(gfree));
                3'd1: consts[gi[CB-1:0]] <= mk(fw_tag, 32'(gfree));
                3'd2: ret_cp[gi[SB-2:0]] <= mk(fw_tag, 32'(gfree));
                3'd3: cp <= mk(fw_tag, 32'(gfree));
                default: heap[scan[HB-1:0]] <= mk(fw_tag, 32'(gfree));
              endcase
              if (gphase == 3'd4) begin
                scan  <= scan + 1'b1;
                state <= S_GC_SCAN;
              end else begin
                gi    <= gi + 8'd1;
                state <= S_GC_ROOT;
              end
            end
          end

          // ---- Proc: 見出し、{先頭 pc | 引数の数 << 16 | nregs << 24}、作ったフレームの bp、外側の Proc
          S_BLOCK: begin
            heap[p_new[HB-1:0]]          <= mk(TAG_HDR, (KIND_PROC << 16) | 3);
            heap[p_new[HB-1:0] + HB'(1)] <= mk_int({c, b});
            heap[p_new[HB-1:0] + HB'(2)] <= mk_int(32'(bp));
            heap[p_new[HB-1:0] + HB'(3)] <= cp;
            pc    <= pc + PC_BITS'(1);
            state <= S_FETCH;
          end

          // ---- 配列リテラル: 見出し 4 語、要素を1つずつ
          S_AHDR: begin
            heap[p_new[HB-1:0]]          <= mk(TAG_HDR, (KIND_ARY << 16) | 2);
            heap[p_new[HB-1:0] + HB'(1)] <= mk_int(32'(m_n));
            heap[p_new[HB-1:0] + HB'(2)] <= mk(TAG_ARRAY, 32'(p_new) + 32'd3);
            heap[p_new[HB-1:0] + HB'(3)] <= mk(TAG_HDR, (KIND_DATA << 16) | 32'(m_n));
            state <= S_AELEM;
          end
          S_AELEM: begin
            if (m_k == (HB+1)'(m_n)) begin
              pc    <= pc + PC_BITS'(1);
              state <= S_FETCH;
            end else begin
              heap[p_new[HB-1:0] + HB'(4) + m_k[HB-1:0]] <= regs[m_src[RB-1:0] + m_k[RB-1:0]];
              m_k <= m_k + 1'b1;
            end
          end

          // ---- 配列への代入 / push: 容量を超えるなら中身を作り直す (確保で GC が走ってもよい)
          S_SET1: begin
            m_len <= s_len;
            m_cap <= lo16(heap[s_d]);
            if (m_i >= lo16(heap[s_d])) begin
              begin
                logic [15:0] nc;
                nc = m_i + 16'd1;
                if (lo16(heap[s_d]) * 2 > nc) nc = lo16(heap[s_d]) * 2;
                if (nc < 16'd4) nc = 16'd4;
                m_cap <= nc;
                need  <= (HB+1)'(nc) + 1'b1;
              end
              mop   <= MO_GROW;
              state <= S_ALLOC;
            end else begin
              m_k   <= (HB+1)'(s_len);
              state <= S_FILL;
            end
          end
          S_GROW: begin
            // p_new: 新しい中身。m_k 語目を写す (長さまでは元の中身、残りは nil)
            if (m_k == '0) heap[p_new[HB-1:0]] <= mk(TAG_HDR, (KIND_DATA << 16) | 32'(m_cap));
            if (m_k == (HB+1)'(m_cap)) begin
              heap[s_p + HB'(2)] <= mk(TAG_ARRAY, 32'(p_new));
              m_k   <= (HB+1)'(m_len);
              state <= S_FILL;
            end else begin
              heap[p_new[HB-1:0] + HB'(1) + m_k[HB-1:0]] <= m_k < (HB+1)'(m_len) ? heap[s_d + HB'(1) + m_k[HB-1:0]] : V_NIL;
              m_k <= m_k + 1'b1;
            end
          end
          S_FILL: begin
            if (m_k >= (HB+1)'(m_i)) state <= S_PUT;
            else begin
              heap[s_d + HB'(1) + m_k[HB-1:0]] <= V_NIL;
              m_k <= m_k + 1'b1;
            end
          end
          S_PUT: begin
            heap[s_d + HB'(1) + m_i[HB-1:0]] <= regs[m_val[RB-1:0]];
            if (m_i >= m_len) heap[s_p + HB'(1)] <= mk_int(32'(m_i) + 32'd1);
            pc    <= pc + PC_BITS'(1);
            state <= S_FETCH;
          end

          // ---- include?: 1 cycle に1要素
          S_INCL: begin
            if (m_k == (HB+1)'(m_len) || m_found) begin
              pc    <= pc + PC_BITS'(1);
              state <= S_FETCH;
            end else begin
              if (eq_of(heap[ha(val_of(heap[ha(val_of(regs[m_dst[RB-1:0]])) + HB'(2)])) + HB'(1) + m_k[HB-1:0]], hold))
                m_found <= 1'b1;
              m_k <= m_k + 1'b1;
            end
          end

          // ---- break (動的): Proc を作ったフレームへ戻るまで1段ずつ畳む
          S_UNWIND: begin
            if (sp == '0) state <= S_ERROR;
            else begin
              bp <= ret_bp[top];
              cp <= ret_cp[top];
              sp <= sp - SB'(1);
              if (ret_bp[top] == target) begin
                pc    <= ret_pc[top];
                state <= S_FETCH;
              end
            end
          end
          // ---- ブロックの中の return: 囲むメソッドのフレームまで畳み、そこから戻る
          S_UNWIND_RET: begin
            if (sp == '0) state <= S_ERROR;
            else begin
              bp <= ret_bp[top];
              cp <= ret_cp[top];
              sp <= sp - SB'(1);
              if (bp == target) begin
                pc    <= ret_pc[top];
                state <= S_FETCH;
              end
            end
          end

          // ---- Proc の連鎖を1段ずつ。walk_left 段たどったら、その Proc を作ったフレームの底
          S_WALK: begin
            if (tag_of(walk_p) != TAG_PROC) state <= S_ERROR;
            else if (walk_left == 4'd0) begin
              fb_base <= RB'(val_of(heap[ha(val_of(walk_p)) + HB'(2)]));
              state   <= S_UPOP;
            end else begin
              walk_p    <= heap[ha(val_of(walk_p)) + HB'(3)];
              walk_left <= walk_left - 4'd1;
            end
          end
          S_UPOP: begin
            if (op == OP_BREAK) begin
              hold   <= ra;
              target <= fb_base;
              state  <= S_UNWIND;
            end else if (op == OP_RETURN_BLK) begin
              hold   <= ra;
              target <= fb_base;
              state  <= S_UNWIND_RET;
            end else if (!u_ok) state <= S_ERROR;
            else begin
              if (op == OP_SETUPVAR) regs[iu[RB-1:0]] <= ra;
              pc    <= pc + PC_BITS'(1);
              state <= S_FETCH;
            end
          end
          S_SLEEP: if (remain == 0) begin
            pc    <= pc + PC_BITS'(1);
            state <= S_FETCH;
          end
          default: ;
        endcase
      end
    end
  end
endmodule
