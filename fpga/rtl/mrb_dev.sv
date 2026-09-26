// コアの周りのデバイス (GPIO、時間、UART、RNG、PWM、ADC、IRQ、watchdog)。番地と意味は tools/fpga/devices.rb (参照モデル) と同じ。
// コアは primitive の __io_read / __io_write で読み書きする (16bit の番地、0x100 から上)。
// 読み出しは組み合わせ。re は読んだ cycle のパルス (UART の RX、RNG、IRQ の登録と事象は読むと進む)。
// tick は命令を始める前 (コアの S_FETCH の en の cycle) のパルスで、ピンを標本にして IRQ の事象を積み、watchdog の期限を見る。
// 期限を過ぎていれば reboot を 1 cycle 出し (soc がコアとポートをリセットする)、自分も初めからにする (watchdog の印は残す)。
//
// 外からの入力: ext_low / ext_high (GPIO のピンを外から L / H にする)、rx_count / rx_bytes (UART が受けたバイトの数と、
// 届いた順のバイト列)、adc_val (ADC の入力 0..4 の 12bit)。シミュレーションのテストベンチが刺激から作る。実機では 0。
// 外への出力: gpio_dir / gpio_out / gpio_level (ピン)、tx_valid / tx_byte (UART の送信)、pwm_running (PWM が動いているピン)。
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
  input  logic                tick,      // 命令を始める前
  input  logic [31:0]         ext_low,
  input  logic [31:0]         ext_high,
  input  logic [15:0]         rx_count,
  input  logic [7:0]          rx_bytes [RX_MAX],
  input  logic [11:0]         adc_val [5],
  output logic [31:0]         gpio_dir,
  output logic [31:0]         gpio_out,
  output logic [31:0]         gpio_level,
  output logic                tx_valid,
  output logic [7:0]          tx_byte,
  output logic [31:0]         pwm_running,
  output logic                reboot
);
  localparam logic [VAL_BITS-1:0] V_NIL = {TAG_NIL, {INT_BITS{1'b0}}};
  localparam logic [15:0] GPIO_DIR = 16'h100, GPIO_OUT = 16'h101, GPIO_PULLUP = 16'h102, GPIO_PULLDOWN = 16'h103,
                          GPIO_OD = 16'h104, GPIO_LEVEL = 16'h105, GPIO_EXT_LOW = 16'h106, GPIO_EXT_HIGH = 16'h107,
                          TIME_US = 16'h110, TIME_US_HI = 16'h111, TIME_MS = 16'h112,
                          UART_TX = 16'h120, UART_RX = 16'h121, UART_AVAIL = 16'h122, RNG = 16'h130,
                          PWM_SEL = 16'h140, PWM_FREQ = 16'h141, PWM_DUTY = 16'h142, PWM_RUNNING = 16'h143,
                          ADC_BASE = 16'h150,
                          IRQ_PIN = 16'h160, IRQ_MASK = 16'h161, IRQ_DEBOUNCE = 16'h162, IRQ_REGISTER = 16'h163,
                          IRQ_ID = 16'h164, IRQ_UNREG = 16'h165, IRQ_EVENT = 16'h166,
                          WDT_ENABLE = 16'h170, WDT_DISABLE = 16'h171, WDT_FEED = 16'h172, WDT_CAUSED = 16'h173,
                          WDT_REMAIN = 16'h174, WDT_REBOOT = 16'h175;
  localparam int NSLOT = 16;  // IRQ の枠 (RP2040 の port と同じ)
  localparam int QLEN  = 32;  // 事象の列 (31 で満杯)

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

  // ---- PWM: ピンごとの周波数 (mHz) と duty (1/1000 %)。配列を always_ff の for で初期化できない (Verilator) ので平らなベクタに
  logic [31:0]      pwm_sel;
  logic [32*32-1:0] pwm_freq, pwm_duty;
  logic             sel_ok;
  assign sel_ok = pwm_sel < 32'd32;
  always_comb for (int p = 0; p < 32; p++) pwm_running[p] = pwm_freq[32*p +: 32] != 32'd0;

  // ---- IRQ: 枠 (ピン、mask、debounce、最後の時刻 (ms)、最後の事象) と事象の列 ({id 5bit, 事象 4bit})
  logic [31:0]          irq_pin, irq_mask, irq_deb, irq_id;
  logic [NSLOT-1:0]     sv;
  logic [NSLOT*32-1:0]  sp, sd, sl;
  logic [NSLOT*4-1:0]   sm, se;
  logic [QLEN*9-1:0]    q;
  logic [4:0]           qh, qt;
  logic                 unreg;
  logic [31:0]          last;
  logic                 have_last;
  // 空いている最初の枠
  logic [4:0] free_i;
  always_comb begin
    free_i = 5'd16;
    for (int i = NSLOT - 1; i >= 0; i--) if (!sv[i]) free_i = 5'(i);
  end
  logic q_empty;
  assign q_empty = qh == qt;

  // ---- watchdog
  logic        wdt_en, caused;
  logic [63:0] wdt_dead;
  logic [31:0] wdt_ms;
  logic        wdt_due;
  assign wdt_due = wdt_en && vtime >= wdt_dead;

  logic [31:0] adc_r;
  always_comb begin
    adc_r = 32'd0;
    for (int i = 0; i < 5; i++) if (addr == ADC_BASE + 16'(i)) adc_r = {20'd0, adc_val[i]};
  end

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
      PWM_SEL:       rdata = {TAG_INT, pwm_sel};
      PWM_FREQ:      rdata = {TAG_INT, sel_ok ? pwm_freq[32*pwm_sel[4:0] +: 32] : 32'd0};
      PWM_DUTY:      rdata = {TAG_INT, sel_ok ? pwm_duty[32*pwm_sel[4:0] +: 32] : 32'd0};
      PWM_RUNNING:   rdata = {TAG_INT, pwm_running};
      ADC_BASE, ADC_BASE + 16'd1, ADC_BASE + 16'd2, ADC_BASE + 16'd3, ADC_BASE + 16'd4: rdata = {TAG_INT, adc_r};
      IRQ_PIN:       rdata = {TAG_INT, irq_pin};
      IRQ_MASK:      rdata = {TAG_INT, irq_mask};
      IRQ_DEBOUNCE:  rdata = {TAG_INT, irq_deb};
      IRQ_ID:        rdata = {TAG_INT, irq_id};
      IRQ_REGISTER:  rdata = {TAG_INT, free_i == 5'd16 ? 32'hFFFF_FFFF : 32'(free_i) + 32'd1};
      IRQ_UNREG:     rdata = {TAG_INT, 31'd0, unreg};
      IRQ_EVENT:     rdata = {TAG_INT, q_empty ? 32'hFFFF_FFFF : {19'd0, q[9*qh +: 5], 4'd0, q[9*qh + 5 +: 4]}}; // id << 8 | 事象
      WDT_CAUSED:    rdata = {TAG_INT, 31'd0, caused};
      WDT_REMAIN:    rdata = {TAG_INT, wdt_en && wdt_dead > vtime ? 32'(wdt_dead - vtime) : 32'd0};
      default:       rdata = V_NIL;
    endcase
  end

  assign tx_valid = we && addr == UART_TX;
  assign tx_byte  = wdata[7:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gpio_dir  <= '0;
      gpio_out  <= '0;
      pull_up   <= '0;
      pull_down <= '0;
      od        <= '0;
      rng       <= 32'd2463534242;
      rp        <= '0;
      pwm_sel   <= '0;
      pwm_freq  <= '0;
      pwm_duty  <= '0;
      irq_pin   <= '0;
      irq_mask  <= '0;
      irq_deb   <= '0;
      irq_id    <= '0;
      sv        <= '0;
      sp        <= '0;
      sd        <= '0;
      sl        <= '0;
      sm        <= '0;
      se        <= '0;
      q         <= '0;
      qh        <= '0;
      qt        <= '0;
      unreg     <= 1'b0;
      last      <= '0;
      have_last <= 1'b0;
      wdt_en    <= 1'b0;
      wdt_dead  <= '0;
      wdt_ms    <= '0;
      caused    <= 1'b0;
      reboot    <= 1'b0;
    end else begin
      reboot <= 1'b0;
      if (tick && wdt_due) begin
        // watchdog の再起動: watchdog の印を残して初めから。UART の届いていたバイトは捨てる
        reboot    <= 1'b1;
        caused    <= 1'b1;
        gpio_dir  <= '0;
        gpio_out  <= '0;
        pull_up   <= '0;
        pull_down <= '0;
        od        <= '0;
        rng       <= 32'd2463534242;
        rp        <= rx_count;
        pwm_sel   <= '0;
        pwm_freq  <= '0;
        pwm_duty  <= '0;
        irq_pin   <= '0;
        irq_mask  <= '0;
        irq_deb   <= '0;
        irq_id    <= '0;
        sv        <= '0;
        qh        <= '0;
        qt        <= '0;
        unreg     <= 1'b0;
        have_last <= 1'b0;
        wdt_en    <= 1'b0;
      end else if (tick) begin
        // ピンの事象 (RP2040 の gpio_irq_callback と同じ): ピンの順に、そのピンの枠の mask の和で絞り、最初に重なる枠へ
        begin : irq_tick
          logic [3:0]  en_m, ev;
          logic [4:0]  t;
          logic [31:0] now_ms;
          logic        done;
          logic [NSLOT*32-1:0] nl;
          logic [NSLOT*4-1:0]  ne;
          logic [QLEN*9-1:0]   nq;
          t      = qt;
          now_ms = vtime[31:0] / 32'd1000;
          nl     = sl;
          ne     = se;
          nq     = q;
          if (have_last && sv != '0) begin
            for (int p = 0; p < 32; p++) begin
              en_m = 4'd0;
              for (int i = 0; i < NSLOT; i++) if (sv[i] && sp[32*i +: 32] == 32'(p)) en_m = en_m | sm[4*i +: 4];
              ev = {!last[p] && gpio_level[p], last[p] && !gpio_level[p], gpio_level[p], !gpio_level[p]} & en_m;
              done = 1'b0;
              if (ev != 4'd0) begin
                for (int i = 0; i < NSLOT; i++) begin
                  if (!done && sv[i] && sp[32*i +: 32] == 32'(p) && (ev & sm[4*i +: 4]) != 4'd0 &&
                      !(sd[32*i +: 32] != 32'd0 && (now_ms - nl[32*i +: 32]) < sd[32*i +: 32] && ev == ne[4*i +: 4])) begin
                    nl[32*i +: 32] = now_ms;
                    ne[4*i +: 4]   = ev;
                    if (5'(t + 5'd1) != qh) begin
                      nq[9*t +: 9] = {ev, 5'(i + 1)};
                      t = t + 5'd1;
                    end
                    done = 1'b1;
                  end
                end
              end
            end
          end
          sl <= nl;
          se <= ne;
          q  <= nq;
          qt <= t;
        end
        last      <= gpio_level;
        have_last <= 1'b1;
      end else begin
        if (we) begin
          case (addr)
            GPIO_DIR:      gpio_dir  <= wdata[31:0];
            GPIO_OUT:      gpio_out  <= wdata[31:0];
            GPIO_PULLUP:   pull_up   <= wdata[31:0];
            GPIO_PULLDOWN: pull_down <= wdata[31:0];
            GPIO_OD:       od        <= wdata[31:0];
            PWM_SEL:       pwm_sel   <= wdata[31:0];
            PWM_FREQ:      if (sel_ok) pwm_freq[32*pwm_sel[4:0] +: 32] <= wdata[31:0];
            PWM_DUTY:      if (sel_ok) pwm_duty[32*pwm_sel[4:0] +: 32] <= wdata[31:0];
            IRQ_PIN:       irq_pin   <= wdata[31:0];
            IRQ_MASK:      irq_mask  <= wdata[31:0];
            IRQ_DEBOUNCE:  irq_deb   <= wdata[31:0];
            IRQ_ID: begin
              irq_id <= wdata[31:0];
              // 解除 (登録されていたかを IRQ_UNREG で読む)
              if (wdata[31:0] >= 32'd1 && wdata[31:0] <= 32'(NSLOT) && sv[wdata[3:0] - 4'd1]) begin
                sv[wdata[3:0] - 4'd1] <= 1'b0;
                unreg <= 1'b1;
              end else unreg <= 1'b0;
            end
            WDT_ENABLE, WDT_REBOOT: begin
              wdt_en   <= 1'b1;
              wdt_dead <= vtime + 64'(wdata[31:0]) * 64'd1000;
              wdt_ms   <= wdata[31:0];
            end
            WDT_DISABLE:   wdt_en <= 1'b0;
            WDT_FEED:      if (wdt_en) wdt_dead <= vtime + 64'(wdt_ms) * 64'd1000;
            default: ;
          endcase
        end
        if (re && addr == UART_RX && avail != 16'd0) rp <= rp + 16'd1;
        if (re && addr == RNG) rng <= rng_next;
        if (re && addr == IRQ_REGISTER && free_i != 5'd16) begin
          sv[free_i[3:0]]           <= 1'b1;
          sp[32*free_i[3:0] +: 32]  <= irq_pin;
          sm[4*free_i[3:0] +: 4]    <= irq_mask[3:0];
          sd[32*free_i[3:0] +: 32]  <= irq_deb;
          sl[32*free_i[3:0] +: 32]  <= 32'd0;
          se[4*free_i[3:0] +: 4]    <= 4'd0;
        end
        if (re && addr == IRQ_EVENT && !q_empty) qh <= qh + 5'd1;
      end
    end
  end
endmodule
