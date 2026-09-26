// mruby バイトコード (RITE0400) を直接実行する CPU コア。多サイクル、1命令 2 cycle (FETCH -> EXEC)。
// メソッド呼び出し (SSEND) だけは、呼び出し先のレジスタを nil で埋めるぶん cycle が増える (S_CLEAR)。
//
// ROM は tools/fpga/rom.rb が作る 48bit 固定長語 ({op, a, b, c})。ジャンプ先・呼び出し先は絶対語アドレス、
// GETGV/SETGV の b は I/O ポート番号、GETCONST/SETCONST の b は定数の番号、SEND の b は組み込みメソッドの番号に
// 解決済み。命令の意味は tools/fpga/ref_vm.rb と同じ (docs/spec.md §10)。ずれたら rake fpga:check が落ちる。
//
// レジスタはレジスタ窓: R[i] はレジスタファイルの bp + i。呼び出し先の bp は呼び出し元の bp + a
// (呼び出し先の R0 = 呼び出し元の R[a])。戻る時は R0 に値を置く。
//
// en が 0 の cycle は何も進まない (実機で CPU を遅く回すためのクロックイネーブル)。
`timescale 1ns / 1ps
module mrb_core
  import mrb_pkg::*;
#(
  parameter int NREGS   = RF_SIZE, // レジスタファイルの大きさ (全フレームで共有)
  parameter int PC_BITS = 10
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                en,

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

  // トレース用 (retire の cycle だけ有効)
  output logic                retire,
  output logic [PC_BITS-1:0]  dbg_pc,
  output logic [7:0]          dbg_op,
  output logic                rf_we,
  output logic [7:0]          rf_waddr,
  output logic [VAL_BITS-1:0] rf_wdata
);
  localparam int RB = $clog2(NREGS);
  localparam int SB = $clog2(STACK_DEPTH + 1);
  localparam int CB = $clog2(NCONST);
  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};
  localparam logic signed [INT_BITS-1:0] INT_MIN = {1'b1, {(INT_BITS-1){1'b0}}};

  // S_INIT: リセット後にレジスタファイルを1本ずつ nil で埋める (en に関係なく毎 cycle 進む)
  typedef enum logic [2:0] { S_INIT, S_FETCH, S_EXEC, S_CLEAR, S_HALT, S_ERROR } state_t;
  state_t state;

  logic [PC_BITS-1:0]  pc;
  logic [VAL_BITS-1:0] regs [NREGS];
  logic [RB-1:0]       bp;
  logic [7:0]          argc;

  // コールスタック: 戻り先の pc と、呼び出し元の bp
  logic [PC_BITS-1:0]  ret_pc [STACK_DEPTH];
  logic [RB-1:0]       ret_bp [STACK_DEPTH];
  logic [SB-1:0]       sp;

  // スタックの一番上 (sp - 1)
  logic [SB-2:0] top;
  assign top = (SB-1)'(sp - SB'(1));

  // 定数 (GETCONST / SETCONST)
  logic [VAL_BITS-1:0] consts [NCONST];
  logic [NCONST-1:0]   cvalid;

  // SSEND で呼び出し先のレジスタを nil で埋める範囲
  logic [RB:0]         clr_ptr, clr_end;

  // ---- decode
  logic [7:0]  op, a;
  logic [15:0] b, c;
  assign op = rom_data[47:40];
  assign a  = rom_data[39:32];
  assign b  = rom_data[31:16];
  assign c  = rom_data[15:0];

  // レジスタファイルでの番号と、範囲に収まっているか (ref_vm.rb の ok?)
  logic [16:0] ia, ia1, ib;
  assign ia  = 17'(bp) + 17'(a);
  assign ia1 = ia + 17'd1;
  assign ib  = 17'(bp) + 17'(b);

  logic a_ok, a1_ok, b_ok;
  assign a_ok  = ia  < 17'(NREGS);
  assign a1_ok = ia1 < 17'(NREGS);
  assign b_ok  = ib  < 17'(NREGS);

  logic [VAL_BITS-1:0] ra, ra1, rb;
  assign ra  = regs[ia[RB-1:0]];
  assign ra1 = regs[ia1[RB-1:0]];
  assign rb  = regs[ib[RB-1:0]];

  logic [1:0] ra_tag, ra1_tag;
  assign ra_tag  = ra[VAL_BITS-1 -: 2];
  assign ra1_tag = ra1[VAL_BITS-1 -: 2];

  logic ra_int, ra1_int, ra_truthy;
  assign ra_int    = ra_tag == TAG_INT;
  assign ra1_int   = ra1_tag == TAG_INT;
  assign ra_truthy = ra_tag == TAG_TRUE || ra_int;

  logic signed [INT_BITS-1:0] x, y;
  assign x = ra[INT_BITS-1:0];
  assign y = ra1[INT_BITS-1:0];

  // Integer 同士は値、それ以外は型 (nil/true/false) が同じなら等しい
  logic eq;
  assign eq = ra_int && ra1_int ? x == y : ra_tag == ra1_tag && !ra_int;

  function automatic logic [VAL_BITS-1:0] mk_int(input logic [INT_BITS-1:0] v);
    return {TAG_INT, v};
  endfunction

  function automatic logic [VAL_BITS-1:0] mk_bool(input logic t);
    return {t ? TAG_TRUE : TAG_FALSE, {INT_BITS{1'b0}}};
  endfunction

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

  // ---- execute (組み合わせ)
  logic                wr;
  logic [VAL_BITS-1:0] wval;
  logic                iow;
  logic [PC_BITS-1:0]  npc;
  logic                halt, err;
  logic                do_call, do_ret, set_const;
  logic [RB:0]         call_bp, call_clr_from, call_clr_to;

  assign io_addr  = b[7:0];
  assign io_wdata = ra;

  // SSEND: c = (呼び出し先の nregs << 8) | 引数の数
  logic [7:0] call_argc, call_nregs;
  assign call_argc  = c[7:0];
  assign call_nregs = c[15:8];
  assign call_bp       = {1'b0, ia[RB-1:0]};
  assign call_clr_from = call_bp + (RB+1)'(call_argc) + (RB+1)'(1);
  assign call_clr_to   = call_bp + (RB+1)'(call_nregs);

  logic [7:0] need;
  assign need = call_nregs > call_argc ? call_nregs : call_argc + 8'd1;

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
      OP_SETGV:     begin iow = 1'b1; err = b[7:0] >= 8'(NPORTS); end
      OP_GETCONST: begin
        wr   = 1'b1;
        wval = consts[b[CB-1:0]];
        err  = b >= 16'(NCONST) || !cvalid[b[CB-1:0]];
      end
      OP_SETCONST: begin set_const = 1'b1; err = b >= 16'(NCONST); end
      OP_JMP:       npc = b[PC_BITS-1:0];
      OP_JMPIF:     if (ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNOT:    if (!ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNIL:    if (ra_tag == TAG_NIL) npc = b[PC_BITS-1:0];
      OP_EQ:        begin wr = 1'b1; err = !a1_ok; wval = mk_bool(eq); end
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
        if (b >= 16'(NBUILTIN) || c != {15'd0, BI_ARGC1[b[3:0]]}) err = 1'b1;
        else if (c == 16'd1 && !a1_ok) err = 1'b1;
        else if (b[7:0] == BI_NOT) wval = mk_bool(!ra_truthy);
        else if (b[7:0] == BI_NEQ) wval = mk_bool(!eq);
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
            default: wval = mk_bool(x[0]); // BI_ODD
          endcase
        end
      end
      OP_SSEND, OP_SSEND0: begin
        do_call = 1'b1;
        npc     = b[PC_BITS-1:0];
        err     = (17'(ia[RB-1:0]) + 17'(need) > 17'(NREGS)) || sp >= SB'(STACK_DEPTH);
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
      OP_STOP: halt = 1'b1;
      default: err = 1'b1;
    endcase

    // a を使う命令は bp + a がレジスタファイルに収まっていること (ref_vm.rb と同じ判定)
    if (!a_ok && !(op == OP_NOP || op == OP_JMP || op == OP_RETNIL || op == OP_STOP)) err = 1'b1;
    if (err) begin
      wr        = 1'b0;
      iow       = 1'b0;
      halt      = 1'b0;
      do_call   = 1'b0;
      do_ret    = 1'b0;
      set_const = 1'b0;
    end
  end

  // ---- 状態遷移
  wire exec = state == S_EXEC && en;

  assign rom_addr = pc;
  assign retire   = exec;
  assign dbg_pc   = pc;
  assign dbg_op   = op;
  // RETURN は呼び出し先の R0 (= bp) に書く
  assign rf_we    = exec && (wr || do_ret);
  assign rf_waddr = do_ret ? 8'(bp) : 8'(ia[RB-1:0]);
  assign rf_wdata = wval;
  assign io_we    = exec && iow;
  assign halted   = state == S_HALT;
  assign error    = state == S_ERROR;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_INIT;
      pc      <= '0;
      bp      <= '0;
      argc    <= '0;
      sp      <= '0;
      cvalid  <= '0;
      clr_ptr <= '0;
      clr_end <= '0;
      // ret_pc / ret_bp / consts はリセットしない。sp と cvalid が有効な所だけを読む
    end else if (state == S_INIT) begin
      // レジスタファイルは一括ではリセットしない (ブロック RAM にできるように)
      regs[clr_ptr[RB-1:0]] <= V_NIL;
      clr_ptr <= clr_ptr + (RB+1)'(1);
      if (clr_ptr == (RB+1)'(NREGS - 1)) state <= S_FETCH;
    end else if (en) begin
      case (state)
        S_FETCH: state <= S_EXEC;
        S_EXEC: begin
          if (wr) regs[ia[RB-1:0]] <= wval;
          if (set_const) begin
            consts[b[CB-1:0]] <= ra;
            cvalid[b[CB-1:0]] <= 1'b1;
          end
          if (err) state <= S_ERROR;
          else if (halt) state <= S_HALT;
          else if (do_call) begin
            ret_pc[sp[SB-2:0]] <= pc + PC_BITS'(1);
            ret_bp[sp[SB-2:0]] <= bp;
            sp                 <= sp + SB'(1);
            regs[ia[RB-1:0]]   <= regs[bp]; // 呼び出し先の R0 = self
            bp                 <= ia[RB-1:0];
            argc               <= call_argc;
            clr_ptr            <= call_clr_from;
            clr_end            <= call_clr_to;
            pc                 <= npc;
            state              <= call_clr_from < call_clr_to ? S_CLEAR : S_FETCH;
          end else if (do_ret) begin
            regs[bp] <= wval;
            bp       <= ret_bp[top];
            sp       <= sp - SB'(1);
            pc       <= npc;
            state    <= S_FETCH;
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
        default: ;
      endcase
    end
  end
endmodule
