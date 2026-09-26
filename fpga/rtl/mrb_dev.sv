// コアの周りのデバイス (GPIO、時間、UART、RNG)。番地と意味は tools/fpga/devices.rb (参照モデル) と同じ。
// コアは primitive の __io_read / __io_write で読み書きする (16bit の番地、0x100 から上)。
// 読み出しは組み合わせ。re は読んだ cycle のパルス (UART の RX と RNG は読むと進む)。
//
// 外からの入力: ext_low / ext_high (GPIO のピンを外から L / H にする)、rx_count / rx_bytes (UART が受けたバイトの数と、
// 届いた順のバイト列。シミュレーションのテストベンチが刺激から作る。実機では 0)。
// 外への出力: gpio_dir / gpio_out / gpio_level (ピン)、tx_valid / tx_byte (UART の送信)。
`timescale 1ns / 1ps
// 値のタグ (wdata の上位) と時計の上位は使わない
/* verilator lint_off UNUSEDSIGNAL */
module mrb_dev
  import mrb_pkg::*;
#(
  parameter int RX_MAX = 256
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [15:0]         addr,
  output logic [VAL_BITS-1:0] rdata,
  input  logic                re,
  input  logic                we,
  input  logic [VAL_BITS-1:0] wdata,
  input  logic [63:0]         vtime,     // 仮想の時計 (µs): 始めた命令の数 + sleep した時間 (コアが数える)
  input  logic [31:0]         ext_low,
  input  logic [31:0]         ext_high,
  input  logic [15:0]         rx_count,
  input  logic [7:0]          rx_bytes [RX_MAX],
  output logic [31:0]         gpio_dir,
  output logic [31:0]         gpio_out,
  output logic [31:0]         gpio_level,
  output logic                tx_valid,
  output logic [7:0]          tx_byte
);
  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};
  localparam logic [15:0] GPIO_DIR = 16'h100, GPIO_OUT = 16'h101, GPIO_PULLUP = 16'h102, GPIO_PULLDOWN = 16'h103,
                          GPIO_OD = 16'h104, GPIO_LEVEL = 16'h105, GPIO_EXT_LOW = 16'h106, GPIO_EXT_HIGH = 16'h107,
                          TIME_US = 16'h110, TIME_US_HI = 16'h111, TIME_MS = 16'h112,
                          UART_TX = 16'h120, UART_RX = 16'h121, UART_AVAIL = 16'h122, RNG = 16'h130;

  logic [31:0] pull_up, pull_down, od, rng;
  logic [15:0] rp; // UART の RX の読んだ数

  // ピンの値: 出力で駆動しているピン (open drain は 0 の時だけ) は出力の値、離しているピンは
  // 外から L > 外から H > pull up (pull down と両方なら down) > 0
  logic [31:0] driven, released;
  assign driven     = gpio_dir & ~(od & gpio_out);
  assign released   = ~ext_low & (ext_high | (pull_up & ~pull_down));
  assign gpio_level = (gpio_out & driven) | (released & ~driven);

  logic [15:0] avail;
  assign avail = rx_count - rp;
  logic [31:0] rng_next;
  logic [31:0] x1, x2;
  assign x1       = rng ^ (rng << 13);
  assign x2       = x1 ^ (x1 >> 17);
  assign rng_next = x2 ^ (x2 << 5);
  logic [63:0] ms;
  assign ms = vtime / 64'd1000;

  always_comb begin
    case (addr)
      GPIO_DIR:      rdata = {TAG_INT, gpio_dir};
      GPIO_OUT:      rdata = {TAG_INT, gpio_out};
      GPIO_PULLUP:   rdata = {TAG_INT, pull_up};
      GPIO_PULLDOWN: rdata = {TAG_INT, pull_down};
      GPIO_OD:       rdata = {TAG_INT, od};
      GPIO_LEVEL:    rdata = {TAG_INT, gpio_level};
      GPIO_EXT_LOW:  rdata = {TAG_INT, ext_low};
      GPIO_EXT_HIGH: rdata = {TAG_INT, ext_high};
      TIME_US:       rdata = {TAG_INT, vtime[31:0]};
      TIME_US_HI:    rdata = {TAG_INT, vtime[63:32]};
      TIME_MS:       rdata = {TAG_INT, ms[31:0]};
      UART_RX:       rdata = {TAG_INT, avail == 16'd0 ? 32'hFFFF_FFFF : {24'd0, rx_bytes[rp[7:0]]}};
      UART_AVAIL:    rdata = {TAG_INT, 16'd0, avail};
      RNG:           rdata = {TAG_INT, rng_next};
      default:       rdata = V_NIL;
    endcase
  end

  assign tx_valid = we && addr == UART_TX;
  assign tx_byte  = wdata[7:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gpio_dir <= '0;
      gpio_out <= '0;
      pull_up   <= '0;
      pull_down <= '0;
      od       <= '0;
      rng      <= 32'd2463534242;
      rp       <= '0;
    end else begin
      if (we) begin
        case (addr)
          GPIO_DIR:      gpio_dir <= wdata[31:0];
          GPIO_OUT:      gpio_out <= wdata[31:0];
          GPIO_PULLUP:   pull_up   <= wdata[31:0];
          GPIO_PULLDOWN: pull_down <= wdata[31:0];
          GPIO_OD:       od       <= wdata[31:0];
          default: ;
        endcase
      end
      if (re && addr == UART_RX && avail != 16'd0) rp <= rp + 16'd1;
      if (re && addr == RNG) rng <= rng_next;
    end
  end
endmodule
