// mruby バイトコード (RITE0400) を直接実行する CPU コア。多サイクル、1命令 2 cycle (FETCH -> EXEC)。
//
// ROM は tools/fpga/rom.rb が作る 48bit 固定長語 ({op, a, b, c})。ジャンプ先は絶対語アドレス、
// GETGV/SETGV の b は I/O ポート番号に解決済み。命令の意味は tools/fpga/ref_vm.rb と同じ
// (docs/spec.md §10)。ずれたら rake fpga:check が落ちる。
//
// en が 0 の cycle は何も進まない (実機で CPU を遅く回すためのクロックイネーブル)。
`timescale 1ns / 1ps
module mrb_core
  import mrb_pkg::*;
#(
  parameter int NREGS   = 16,
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

  typedef enum logic [1:0] { S_FETCH, S_EXEC, S_HALT, S_ERROR } state_t;
  state_t state;

  logic [PC_BITS-1:0]  pc;
  logic [VAL_BITS-1:0] regs [NREGS];

  // ---- decode
  logic [7:0]  op, a;
  logic [15:0] b, c;
  assign op = rom_data[47:40];
  assign a  = rom_data[39:32];
  assign b  = rom_data[31:16];
  assign c  = rom_data[15:0];

  logic a_ok, a1_ok, b_ok;
  assign a_ok  = {8'd0, a} < 16'(NREGS);
  assign a1_ok = {8'd0, a} + 16'd1 < 16'(NREGS);
  assign b_ok  = b < 16'(NREGS);

  logic [RB-1:0] a_idx, a1_idx, b_idx;
  assign a_idx  = a[RB-1:0];
  assign a1_idx = a_idx + RB'(1);
  assign b_idx  = b[RB-1:0];

  logic [VAL_BITS-1:0] ra, ra1, rb;
  assign ra  = regs[a_idx];
  assign ra1 = regs[a1_idx];
  assign rb  = regs[b_idx];

  logic ra_int, ra1_int, ra_truthy;
  assign ra_int    = ra[VAL_BITS-1 -: 2] == TAG_INT;
  assign ra1_int   = ra1[VAL_BITS-1 -: 2] == TAG_INT;
  assign ra_truthy = ra[VAL_BITS-1 -: 2] == TAG_TRUE || ra_int;

  logic signed [INT_BITS-1:0] x, y;
  assign x = ra[INT_BITS-1:0];
  assign y = ra1[INT_BITS-1:0];

  function automatic logic [VAL_BITS-1:0] mk_int(input logic [INT_BITS-1:0] v);
    return {TAG_INT, v};
  endfunction

  function automatic logic [VAL_BITS-1:0] mk_bool(input logic t);
    return {t ? TAG_TRUE : TAG_FALSE, {INT_BITS{1'b0}}};
  endfunction

  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};

  // ---- execute (組み合わせ)
  logic                wr;
  logic [VAL_BITS-1:0] wval;
  logic                iow;
  logic [PC_BITS-1:0]  npc;
  logic                halt, err;

  assign io_addr  = b[7:0];
  assign io_wdata = ra;

  always_comb begin
    wr   = 1'b0;
    wval = V_NIL;
    iow  = 1'b0;
    npc  = pc + PC_BITS'(1);
    halt = 1'b0;
    err  = 1'b0;

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
      OP_LOADNIL:   begin wr = 1'b1; wval = V_NIL; end
      OP_LOADTRUE:  begin wr = 1'b1; wval = mk_bool(1'b1); end
      OP_LOADFALSE: begin wr = 1'b1; wval = mk_bool(1'b0); end
      OP_GETGV:     begin wr = 1'b1; wval = io_rdata; err = b[7:0] >= 8'(NPORTS); end
      OP_SETGV:     begin iow = 1'b1; err = b[7:0] >= 8'(NPORTS); end
      OP_JMP:       npc = b[PC_BITS-1:0];
      OP_JMPIF:     if (ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNOT:    if (!ra_truthy) npc = b[PC_BITS-1:0];
      OP_JMPNIL:    if (ra[VAL_BITS-1 -: 2] == TAG_NIL) npc = b[PC_BITS-1:0];
      OP_ADD, OP_SUB, OP_LT, OP_LE, OP_GT, OP_GE: begin
        wr  = 1'b1;
        err = !a1_ok || !(ra_int && ra1_int);
        case (op)
          OP_ADD:  wval = mk_int(x + y);
          OP_SUB:  wval = mk_int(x - y);
          OP_LT:   wval = mk_bool(x < y);
          OP_LE:   wval = mk_bool(x <= y);
          OP_GT:   wval = mk_bool(x > y);
          default: wval = mk_bool(x >= y);
        endcase
      end
      OP_EQ: begin
        wr   = 1'b1;
        err  = !a1_ok;
        // Integer 同士は値、それ以外は型 (nil/true/false) が同じなら等しい
        wval = mk_bool(ra_int && ra1_int ? x == y
                                         : ra[VAL_BITS-1 -: 2] == ra1[VAL_BITS-1 -: 2] && !ra_int);
      end
      OP_ADDI:   begin wr = 1'b1; err = !ra_int; wval = mk_int(x + {24'd0, b[7:0]}); end
      OP_SUBI:   begin wr = 1'b1; err = !ra_int; wval = mk_int(x - {24'd0, b[7:0]}); end
      OP_ADDILV: begin wr = 1'b1; err = !ra_int; wval = mk_int(x + {24'd0, c[7:0]}); end
      OP_SUBILV: begin wr = 1'b1; err = !ra_int; wval = mk_int(x - {24'd0, c[7:0]}); end
      OP_RETURN, OP_RETNIL, OP_STOP: halt = 1'b1;
      default: err = 1'b1;
    endcase

    // a を使う命令は a がレジスタファイルに収まっていること (ref_vm.rb と同じ判定)
    if (!a_ok && !(op == OP_NOP || op == OP_JMP || op == OP_RETNIL || op == OP_STOP)) err = 1'b1;
    if (err) begin
      wr   = 1'b0;
      iow  = 1'b0;
      halt = 1'b0;
    end
  end

  // ---- 状態遷移
  wire exec = state == S_EXEC && en;

  assign rom_addr = pc;
  assign retire   = exec;
  assign dbg_pc   = pc;
  assign dbg_op   = op;
  assign rf_we    = exec && wr;
  assign rf_waddr = a;
  assign rf_wdata = wval;
  assign io_we    = exec && iow;
  assign halted   = state == S_HALT;
  assign error    = state == S_ERROR;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_FETCH;
      pc    <= '0;
      for (int i = 0; i < NREGS; i++) regs[i] <= V_NIL;
    end else if (en) begin
      case (state)
        S_FETCH: state <= S_EXEC;
        S_EXEC: begin
          if (wr) regs[a_idx] <= wval;
          if (err) state <= S_ERROR;
          else if (halt) state <= S_HALT;
          else begin
            pc    <= npc;
            state <= S_FETCH;
          end
        end
        default: ;
      endcase
    end
  end
endmodule
