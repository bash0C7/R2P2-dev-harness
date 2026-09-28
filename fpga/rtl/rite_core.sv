// mruby のバイトコード (.mrb、RITE0400) を ROM から直接読んで実行する CPU の最初の反復 (issue #4)。
// 範囲は Lチカ (fpga/rite/blink.rb) に出る命令と、そのメソッドだけ。範囲の外の命令やメソッドに当たると
// error を立てて止まる (黙って違うことをしない)。
//
// - 命令 (include/mruby/ops.h の番号と operand の形): NOP MOVE LOADI8 LOADINEG LOADI__1〜LOADI_7 LOADI16
//   LOADNIL LOADSELF GETCONST GETMCNST JMP SSEND SEND RETURN RETNIL STOP
// - メソッド (回路の組み込み): GPIO (定数)、GPIO::OUT / GPIO::IN、GPIO.new(pin, flags)、GPIO#write(0|1)、sleep_ms(ms)
//   GPIO.new は picoruby-gpio の initialize の _init (GPIO_init) と set_dir (GPIO_set_dir) に当たる所だけ
// - 値: nil、Integer (32bit。mruby の 64bit でない)、GPIO のクラス、GPIO の object (pin)、main。レジスタは 16 本
// - ピンの水準は host の板のモデル (firmware-patches/posix-board-gpio.patch) と同じ式: (dir & out) | (~dir & ~pull_down)、
//   pull_down は無いので入力のピンは 1
// - 時刻: MS_CYCLES の cycle ごとに ms を 1 進める。sleep_ms(n) は呼んだ時の ms + n まで待つ
//
// 起動: 見出し "RITE0400" と section "IREP" を確かめ、最初の irep の ilen から pool の位置を得て、pool が 0 個であることを
// 確かめ、sym の名前を組み込みの名前と照らして表にする。その後 iseq (48 バイト目) から実行する。
//
// 実行: 1 命令を「命令のバイト → operand → レジスタを 3 本読む (a か b、a+1、a+2) → 実行」の順に 1 バイトずつ、1 本ずつ進める。
// レジスタの読みは 1 cycle に 1 本、書きは 1 本 (次の cycle に書く)。速さより小さく浅くする反復
`timescale 1ns / 1ps
module rite_core #(
  parameter int ROM_BYTES = 1024,
  parameter     ROM_FILE  = "",     // $readmemh の file (1 行 1 バイト)。型を付けると Icarus が渡せない
  parameter int MS_CYCLES = 50_000  // 1 ms の cycle 数 (CLOCK_50 なら 50,000)
) (
  input  logic        clk,
  input  logic        rst_n,
  output logic [31:0] pins,       // ピンの水準 (bit n = pin n)
  output logic [31:0] ms_now,     // 起動からの ms
  output logic        halted,     // 正しく終わった (RETURN / RETNIL / STOP)
  output logic        error,      // 範囲の外に当たって止まった
  output logic [7:0]  error_op,   // その時の命令
  output logic [15:0] error_pc    // その時の命令の番地
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

  // ---- 値とレジスタ (読み 1 本、書き 1 本) ----
  localparam logic [2:0] T_NIL = 3'd0, T_INT = 3'd1, T_GPIO_CLASS = 3'd2, T_GPIO = 3'd3, T_MAIN = 3'd4;
  typedef struct packed { logic [2:0] tag; logic [31:0] val; } value_t;
  localparam int NREGS = 16;
  value_t     regs [0:NREGS-1];
  logic [3:0] ridx;            // 読むレジスタ (この cycle の regs[ridx] が rd)
  value_t     rd;
  assign rd = regs[ridx];
  logic       we;              // 次の cycle に regs[widx] へ wval を書く
  logic [3:0] widx;
  value_t     wval;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < NREGS; i++) regs[i] <= {T_NIL, 32'd0};
    end else if (we) begin
      regs[widx] <= wval;
    end

  // ---- 組み込みの名前 (sym の表の値) ----
  localparam logic [2:0] B_NONE = 3'd0, B_GPIO = 3'd1, B_OUT = 3'd2, B_IN = 3'd3, B_NEW = 3'd4, B_WRITE = 3'd5,
                         B_SLEEP_MS = 3'd6;
  localparam int NB = 6;
  function automatic logic [3:0] bname_len(input logic [2:0] id);
    case (id)
      B_GPIO: return 4'd4;  B_OUT: return 4'd3;  B_IN: return 4'd2;  B_NEW: return 4'd3;
      B_WRITE: return 4'd5; B_SLEEP_MS: return 4'd8; default: return 4'd0;
    endcase
  endfunction
  function automatic logic [7:0] bname_char(input logic [2:0] id, input logic [3:0] p);
    logic [63:0] s;
    case (id)
      B_GPIO:     s = "GPIO";
      B_OUT:      s = "OUT";
      B_IN:       s = "IN";
      B_NEW:      s = "new";
      B_WRITE:    s = "write";
      B_SLEEP_MS: s = "sleep_ms";
      default:    s = '0;
    endcase
    // 文字列の定数は右詰め: 長さ L の名前の p 文字目は s の上から
    return (p < bname_len(id)) ? s[8*(bname_len(id) - 4'd1 - p) +: 8] : 8'd0;
  endfunction

  localparam int NSYMS = 16;
  logic [2:0] sym_b [0:NSYMS-1];

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

  // ---- 状態 ----
  typedef enum logic [3:0] {
    S_HDR, S_ILEN, S_POOL, S_SLEN, S_SYMLEN, S_SYMCHR, S_SYMNUL,
    S_OP, S_OPND, S_RD0, S_RD1, S_RD2, S_EXEC, S_SLEEP, S_HALT, S_ERR
  } state_t;
  state_t        st;
  logic          rd_wait;   // rom_addr を出した次の cycle (rom_q がまだ古い)
  logic [AW-1:0] ptr;
  logic [4:0]    hdr_i;
  logic [23:0]   acc;       // 見出しの数や operand を集める
  logic [2:0]    cnt;       // 集めたバイト数
  logic [15:0]   nsyms;
  logic [3:0]    sym_i;
  logic [15:0]   sym_len;
  logic [3:0]    chr_i;
  logic [NB:1]   match;
  logic [7:0]    op, a_q;
  logic [2:0]    nopnd;
  logic [AW-1:0] op_pc;
  logic [31:0]   wake_ms;
  value_t        v0, v1;     // 読んだレジスタ: a か b、a+1 (a+2 は S_EXEC の rd)

  // 見出しで確かめるバイト: "RITE0400" (0..7) と "IREP" (20..23)
  function automatic logic hdr_ok(input logic [4:0] i, input logic [7:0] b);
    case (i)
      5'd0: return b == "R";  5'd1: return b == "I";  5'd2: return b == "T";  5'd3: return b == "E";
      5'd4: return b == "0";  5'd5: return b == "4";  5'd6: return b == "0";  5'd7: return b == "0";
      5'd20: return b == "I"; 5'd21: return b == "R"; 5'd22: return b == "E"; 5'd23: return b == "P";
      default: return 1'b1;
    endcase
  endfunction

  // operand のバイト数 (ops.h の Z / B / BB / S / BS / BBB)。範囲の外は 7
  function automatic logic [2:0] opnd_bytes(input logic [7:0] o);
    case (o)
      8'd0, 8'd64, 8'd118:                                return 3'd0; // NOP RETNIL STOP
      8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13,
      8'd17, 8'd18, 8'd61:                                return 3'd1; // LOADI__1..LOADI_7 LOADNIL LOADSELF RETURN
      8'd1, 8'd3, 8'd4, 8'd29, 8'd31, 8'd38:              return 3'd2; // MOVE LOADI8 LOADINEG GETCONST GETMCNST JMP (S)
      8'd14, 8'd47, 8'd50:                                return 3'd3; // LOADI16 (BS) SSEND SEND (BBB)
      default:                                            return 3'd7;
    endcase
  endfunction

  // operand: 最初のバイトは a_q、残りは acc に詰める。B: a / BB: a b / S: {a_q, acc} / BS: a S / BBB: a b c
  logic [7:0] ob, oc;
  assign ob = (nopnd == 3'd3) ? acc[15:8] : acc[7:0];
  assign oc = acc[7:0];
  logic [3:0] ra;
  assign ra = a_q[3:0];

  // 実行の前に確かめること: sym の番号が表の中、レジスタが 16 本の中 (SEND と SSEND は引数まで)
  logic uses_sym, is_send, bad_opnd;
  assign uses_sym = (op == 8'd29 || op == 8'd31 || op == 8'd47 || op == 8'd50);
  assign is_send  = (op == 8'd47 || op == 8'd50);
  assign bad_opnd = (uses_sym && 16'(ob) >= nsyms) ||
                    (nopnd != 3'd0 && op != 8'd38 && a_q[7:4] != 4'd0) ||
                    (is_send && 5'(a_q[3:0]) + 5'(oc) > 5'd15) ||
                    (op == 8'd1 && ob[7:4] != 4'd0);

  logic [2:0] bsym;   // b の sym の組み込みの名前
  assign bsym = sym_b[ob[3:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_HDR; rd_wait <= 1'b1; ptr <= '0; rom_addr <= '0; hdr_i <= '0;
      acc <= '0; cnt <= '0; nsyms <= '0; sym_i <= '0; sym_len <= '0; chr_i <= '0; match <= '0;
      op <= '0; a_q <= '0; nopnd <= '0; op_pc <= '0; wake_ms <= '0;
      ridx <= '0; we <= 1'b0; widx <= '0; wval <= '0; v0 <= '0; v1 <= '0;
      gpio_we <= 1'b0; gpio_set_dir <= 1'b0; gpio_out_v <= 1'b0; gpio_dir_v <= 1'b0; gpio_pin <= '0;
      halted <= 1'b0; error <= 1'b0; error_op <= '0; error_pc <= '0;
      for (int i = 0; i < NSYMS; i++) sym_b[i] <= B_NONE;
    end else begin
      we <= 1'b0;
      gpio_we <= 1'b0;
      if (rd_wait) begin
        rd_wait <= 1'b0;   // rom_q は次の cycle に rom[rom_addr] になる
      end else begin
        case (st)
          // 見出し 0..23 を確かめる
          S_HDR: begin
            if (!hdr_ok(hdr_i, rom_q)) begin st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr); end
            else if (hdr_i == 5'd23) begin
              st <= S_ILEN; ptr <= AW'(44); rom_addr <= AW'(44); rd_wait <= 1'b1; cnt <= '0; acc <= '0;
            end else begin
              hdr_i <= hdr_i + 5'd1; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            end
          end
          // irep の record の ilen (44..47、big endian)。上の 2 バイトは 0 だけ。pool は 48 + ilen から
          S_ILEN: begin
            acc <= {acc[15:0], rom_q};
            if (cnt == 3'd3) begin
              if (acc[23:8] != 16'd0) begin st <= S_ERR; error_pc <= 16'(ptr); end
              else begin
                ptr <= AW'(48) + AW'({acc[7:0], rom_q}); rom_addr <= AW'(48) + AW'({acc[7:0], rom_q});
                rd_wait <= 1'b1; cnt <= '0; acc <= '0; st <= S_POOL;
              end
            end else begin
              cnt <= cnt + 3'd1; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            end
          end
          // pool の数は 0 だけ (Lチカに文字列や大きい数は無い)
          S_POOL: begin
            acc <= {acc[15:0], rom_q};
            ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            if (cnt == 3'd1) begin
              if ({acc[7:0], rom_q} != 16'd0) begin st <= S_ERR; error_pc <= 16'(ptr); end
              else begin st <= S_SLEN; cnt <= '0; acc <= '0; end
            end else cnt <= cnt + 3'd1;
          end
          // sym の数 (16 まで)
          S_SLEN: begin
            acc <= {acc[15:0], rom_q};
            ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            if (cnt == 3'd1) begin
              nsyms <= {acc[7:0], rom_q}; sym_i <= '0; cnt <= '0; acc <= '0;
              if ({acc[7:0], rom_q} > 16'(NSYMS)) begin st <= S_ERR; error_pc <= 16'(ptr); end
              else if ({acc[7:0], rom_q} == 16'd0) begin st <= S_OP; ptr <= AW'(48); rom_addr <= AW'(48); end
              else st <= S_SYMLEN;
            end else cnt <= cnt + 3'd1;
          end
          // 1 つの sym: 長さ (2 バイト、0xFFFF は名前の無い sym)、名前、NUL
          S_SYMLEN: begin
            acc <= {acc[15:0], rom_q};
            if (cnt == 3'd1) begin
              sym_len <= {acc[7:0], rom_q}; chr_i <= '0; match <= '1; cnt <= '0; acc <= '0;
              if ({acc[7:0], rom_q} == 16'hFFFF) begin   // 名前の無い sym (長さだけで NUL も無い)
                sym_b[sym_i] <= B_NONE;
                if (5'(sym_i) + 5'd1 == 5'(nsyms)) begin st <= S_OP; ptr <= AW'(48); rom_addr <= AW'(48); end
                else begin sym_i <= sym_i + 4'd1; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); end
              end else begin
                st <= ({acc[7:0], rom_q} == 16'd0) ? S_SYMNUL : S_SYMCHR;
                ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1);
              end
              rd_wait <= 1'b1;
            end else begin
              cnt <= cnt + 3'd1; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            end
          end
          // 名前を 1 文字ずつ組み込みの名前と照らす。16 文字を超える名前は組み込みに無いので読み飛ばす
          S_SYMCHR: begin
            for (int k = 1; k <= NB; k++)
              if (chr_i >= bname_len(3'(k)) || rom_q != bname_char(3'(k), chr_i)) match[k] <= 1'b0;
            rd_wait <= 1'b1;
            if (16'(chr_i) + 16'd1 == sym_len) begin
              st <= S_SYMNUL; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1);
            end else if (chr_i == 4'd15) begin
              st <= S_SYMNUL; match <= '0;
              ptr <= ptr + AW'(sym_len - 16'd15); rom_addr <= ptr + AW'(sym_len - 16'd15);
            end else begin
              ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1);
            end
            chr_i <= chr_i + 4'd1;
          end
          // NUL を読み、表に入れる (長さも一致したものだけ)
          S_SYMNUL: begin
            sym_b[sym_i] <= B_NONE;
            for (int k = 1; k <= NB; k++)
              if (match[k] && 16'(bname_len(3'(k))) == sym_len) sym_b[sym_i] <= 3'(k);
            rd_wait <= 1'b1;
            if (5'(sym_i) + 5'd1 == 5'(nsyms)) begin
              st <= S_OP; ptr <= AW'(48); rom_addr <= AW'(48);
            end else begin
              sym_i <= sym_i + 4'd1; st <= S_SYMLEN; ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1);
            end
          end

          // ---- 実行 ----
          S_OP: begin
            op <= rom_q; op_pc <= ptr; nopnd <= opnd_bytes(rom_q); cnt <= '0; acc <= '0; a_q <= '0;
            ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            if (opnd_bytes(rom_q) == 3'd7) begin
              st <= S_ERR; error_op <= rom_q; error_pc <= 16'(ptr);
            end else if (opnd_bytes(rom_q) == 3'd0) st <= S_RD0;
            else st <= S_OPND;
          end
          S_OPND: begin
            if (cnt == 3'd0) a_q <= rom_q; else acc <= {acc[15:0], rom_q};
            ptr <= ptr + AW'(1); rom_addr <= ptr + AW'(1); rd_wait <= 1'b1;
            if (cnt + 3'd1 == nopnd) st <= S_RD0;
            cnt <= cnt + 3'd1;
          end
          // レジスタを読む: MOVE は b、ほかは a。続けて a+1、a+2
          S_RD0: begin
            if (bad_opnd) begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
            else begin ridx <= (op == 8'd1) ? ob[3:0] : ra; st <= S_RD1; end
          end
          S_RD1: begin v0 <= rd; ridx <= ra + 4'd1; st <= S_RD2; end
          S_RD2: begin v1 <= rd; ridx <= ra + 4'd2; st <= S_EXEC; end
          S_EXEC: begin
            st <= S_OP;   // 次の命令は ptr から (JMP だけ変える)。rom_addr は ptr を指したまま
            widx <= ra;
            case (op)
              8'd0: ;                                                                    // NOP
              8'd1: begin we <= 1'b1; wval <= v0; end                                    // MOVE
              8'd3: begin we <= 1'b1; wval <= {T_INT, {24'd0, ob}}; end        // LOADI8
              8'd4: begin we <= 1'b1; wval <= {T_INT, -{24'd0, ob}}; end       // LOADINEG
              8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10, 8'd11, 8'd12, 8'd13:                  // LOADI__1..LOADI_7
                begin we <= 1'b1; wval <= {T_INT, 32'(op) - 32'd6}; end
              8'd14: begin we <= 1'b1; wval <= {T_INT, {{16{acc[15]}}, acc[15:0]}}; end // LOADI16
              8'd17: begin we <= 1'b1; wval <= {T_NIL, 32'd0}; end               // LOADNIL
              8'd18: begin we <= 1'b1; wval <= {T_MAIN, 32'd0}; end              // LOADSELF
              8'd29: begin                                                               // GETCONST
                if (bsym == B_GPIO) begin we <= 1'b1; wval <= {T_GPIO_CLASS, 32'd0}; end
                else begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
              end
              8'd31: begin                                                               // GETMCNST R[a]::Syms[b]
                if (v0.tag == T_GPIO_CLASS && bsym == B_OUT) begin we <= 1'b1; wval <= {T_INT, FLAG_OUT}; end
                else if (v0.tag == T_GPIO_CLASS && bsym == B_IN) begin we <= 1'b1; wval <= {T_INT, FLAG_IN}; end
                else begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
              end
              8'd38: begin                                                               // JMP pc += S
                ptr <= ptr + AW'({a_q, acc[7:0]}); rom_addr <= ptr + AW'({a_q, acc[7:0]}); rd_wait <= 1'b1;
              end
              8'd47: begin                                                               // SSEND (self は main)
                if (bsym == B_SLEEP_MS && oc == 8'd1 && v1.tag == T_INT && !v1.val[31]) begin
                  wake_ms <= ms_now + v1.val;
                  we <= 1'b1; wval <= {T_NIL, 32'd0};
                  st <= S_SLEEP;
                end else begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
              end
              8'd50: begin                                                               // SEND
                if (bsym == B_NEW && oc == 8'd2 && v0.tag == T_GPIO_CLASS && v1.tag == T_INT && rd.tag == T_INT &&
                    (rd.val == FLAG_OUT || rd.val == FLAG_IN)) begin
                  // GPIO_init (入力、latch 0) と GPIO_set_dir。pin 32 以上は何もしない
                  gpio_we <= (v1.val < 32'd32); gpio_pin <= v1.val[4:0]; gpio_out_v <= 1'b0;
                  gpio_set_dir <= 1'b1; gpio_dir_v <= (rd.val == FLAG_OUT);
                  we <= 1'b1; wval <= {T_GPIO, v1.val};
                end else if (bsym == B_WRITE && oc == 8'd1 && v0.tag == T_GPIO && v1.tag == T_INT &&
                             (v1.val == 32'd0 || v1.val == 32'd1)) begin
                  gpio_we <= (v0.val < 32'd32); gpio_pin <= v0.val[4:0]; gpio_out_v <= v1.val[0]; gpio_set_dir <= 1'b0;
                  we <= 1'b1; wval <= {T_INT, 32'd0};
                end else begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
              end
              8'd61, 8'd64, 8'd118: st <= S_HALT;                                        // RETURN RETNIL STOP
              default: begin st <= S_ERR; error_op <= op; error_pc <= 16'(op_pc); end
            endcase
          end
          S_SLEEP: if ($signed(ms_now - wake_ms) >= 0) st <= S_OP;
          S_HALT:  halted <= 1'b1;
          S_ERR:   error <= 1'b1;
          default: st <= S_ERR;
        endcase
      end
    end
  end
endmodule

