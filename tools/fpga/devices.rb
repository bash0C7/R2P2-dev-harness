# CPU コアの周りのデバイス (GPIO、時間、UART、RNG、PWM、ADC、IRQ、watchdog、I2C、SPI、PSG の列) の参照モデル。docs/spec.md §10「デバイス (P5)」。
#
# コアは primitive の __io_read(addr) / __io_write(addr, value) でデバイスのレジスタを読み書きする (16bit の番地、
# レジスタは 32bit。読んだ値は符号付きに広げた 64bit の Integer (-1 は -1)、ただし TIME_US と TIME_MS は 64bit の時計そのもの。
# 書くのは下の 32bit)。RTL (fpga/rtl/mrb_dev.sv) と参照インタプリタ (ref_vm.rb) と、CRuby での突き合わせ
# (oracle.rb が __io_read / __io_write をこのモデルで定義する) が同じ形で動く。
#
# 外からの入力は刺激 ([step, 番地, 値]) で与える: GPIO の EXT_LOW / EXT_HIGH はその step からの値 (最後が勝つ)、
# UART・I2C・SPI の返事 (RX) は1行が1バイトで、その step から読める (届いた順)、ADC の入力と I2C の応答する番地は
# その step からの値。外のチップ (表示器など) への書き込みはトレースの O 行に出るだけ (表示は emu のデコーダー)。
#
# 各命令を始める前に tick を呼ぶ (ピンの標本、IRQ の事象、watchdog の期限)。RTL は S_FETCH の終わりで同じことをする。
module FpgaDevices
  GPIO_DIR      = 0x100 # 1 = 出力
  GPIO_OUT      = 0x101 # 出力の値
  GPIO_PULLUP   = 0x102
  GPIO_PULLDOWN = 0x103
  GPIO_OD       = 0x104 # open drain (出力の 1 は離す)
  GPIO_LEVEL    = 0x105 # ピンの今の値 (読むだけ)
  GPIO_EXT_LOW  = 0x106 # 外から L に落としているピン (刺激)
  GPIO_EXT_HIGH = 0x107 # 外から H にしているピン (刺激)
  TIME_US       = 0x110 # 仮想の時計 (µs、64bit): 始めた命令の数 + sleep した時間
  TIME_US_HI    = 0x111
  TIME_MS       = 0x112 # 仮想の時計 / 1000 (64bit)
  UART_TX       = 0x120 # 書くと1バイト送る
  UART_RX       = 0x121 # 読むと受けた1バイト (無ければ -1)
  UART_AVAIL    = 0x122 # 受けて読んでいないバイトの数
  UART_BAUD     = 0x123 # 書くだけ (シミュレーションでは意味を持たない)
  RNG           = 0x130 # 読むたびに xorshift32 の次の値
  RNG_SEED      = 2_463_534_242
  PWM_SEL       = 0x140 # 設定するピン
  PWM_FREQ      = 0x141 # 周波数 (mHz)。0 は止める
  PWM_DUTY      = 0x142 # duty (1/1000 %)
  PWM_RUNNING   = 0x143 # 動いているピンの bit (読むだけ)
  ADC_BASE      = 0x150 # 0x150..0x154: 入力 0..3 (ピン 26..29) と 4 (温度) の生の値 (12bit、刺激)
  ADC_INPUTS    = 5
  IRQ_PIN       = 0x160 # 登録するピン
  IRQ_MASK      = 0x161 # 事象の mask (LEVEL_LOW 1、LEVEL_HIGH 2、EDGE_FALL 4、EDGE_RISE 8)
  IRQ_DEBOUNCE  = 0x162 # ms
  IRQ_REGISTER  = 0x163 # 読むと登録して id (1..16、空きが無ければ -1)
  IRQ_ID        = 0x164 # 解除する id
  IRQ_UNREG     = 0x165 # 読むと解除して、登録されていたら 1
  IRQ_EVENT     = 0x166 # 読むと列の先頭を取る (id << 8 | 事象、空なら -1)
  IRQ_SLOTS     = 16
  IRQ_QUEUE     = 32 # 31 で満杯 (RP2040 の port と同じ)
  WDT_ENABLE    = 0x170 # ms を書くと有効 (期限 = 今 + ms)
  WDT_DISABLE   = 0x171
  WDT_FEED      = 0x172 # 期限をのばす
  WDT_CAUSED    = 0x173 # watchdog で再起動したか (1 / 0)
  WDT_REMAIN    = 0x174 # 期限までの µs (無効なら 0)
  WDT_REBOOT    = 0x175 # ms を書くとその後に再起動
  I2C_ADDR      = 0x180 # 7bit の番地を書く (始め)
  I2C_TX        = 0x181 # 1バイト送る
  I2C_ACK       = 0x182 # その番地が応答するか (1 / 0)
  I2C_STOP      = 0x183 # 終わり
  I2C_RX        = 0x184 # 返事の次のバイト (刺激。無ければ 0xFF)
  I2C_PRESENT   = 0x185 # 0x185..0x188: 応答する番地の bit (番地 32k..32k+31 が 0x185+k。刺激で与える)
  I2C_PRESENT_DEFAULT = [0, 0x5000_0000, 0, 0].freeze # 0x3C (SSD1306) と 0x3E (AQM0802 の LCD)
  SPI_TX        = 0x190 # 1バイト送る
  SPI_RX        = 0x191 # 返事の次のバイト (刺激。無ければ 0xFF)
  # PSG のパケットの列 (P5e、C の ports/common/psg.c の ring buffer と rp2040 port の psg_process_packets)。
  # PSG そのもの (音) は FPGA の外。取り出したパケットはトレースの P 行になる
  PSG_DELAY     = 0x1A0 # 次に積むパケットの遅延 (ms)
  PSG_AUX       = 0x1A1 # 次に積むパケットの aux (16bit)
  PSG_PUSH      = 0x1A2 # {op, reg, val, arg} を書くと積む (満杯か止めていれば捨てる)
  PSG_FREE      = 0x1A3 # 空きの数 (止めていれば 0)
  PSG_EMPTY     = 0x1A4 # 空なら 1。書くと列を捨てる (buffer_flush)
  PSG_SELECT    = 0x1A5 # 出力 (0 止める、1 PWM、2 MCP4922)。書くと列と時計を初めから (C の reset_psg / deinit)
  PSG_DIRECT_REG  = 0x1A6 # {reg, val} を列を通さずに (write_reg_direct)
  PSG_DIRECT_MUTE = 0x1A7 # {tr, flag} を列を通さずに (mute_direct)
  PSG_SLOTS     = 256 # 255 まで入る
  PSG_OP_DIRECT_REG  = 0x80 # P 行の op (列を通さない書き込み)
  PSG_OP_DIRECT_MUTE = 0x81
  # 刺激で与える番地 (レベル)
  LEVEL_INPUTS = [GPIO_EXT_LOW, GPIO_EXT_HIGH, *(ADC_BASE...ADC_BASE + ADC_INPUTS), *(I2C_PRESENT...I2C_PRESENT + 4)].freeze
  # 刺激で与える番地 (届いた順のバイトの列)
  QUEUE_INPUTS = [UART_RX, I2C_RX, SPI_RX].freeze
  REGS = [GPIO_DIR, GPIO_OUT, GPIO_PULLUP, GPIO_PULLDOWN, GPIO_OD, PWM_SEL, IRQ_PIN, IRQ_MASK, IRQ_DEBOUNCE, IRQ_ID,
          I2C_ADDR].freeze
  MASK = 0xFFFF_FFFF

  def self.device?(addr)
    addr >= 0x100
  end

  # 1台分の状態
  class Bank
    attr_reader :regs

    # stim: [[step, addr, value], ...] (FpgaCompare.sort_stim の順)
    def initialize(stim = [])
      # 番地ごとの [[step, バイト], ...]
      @queues = QUEUE_INPUTS.to_h { |q| [q, stim.select { |_, a, _| a == q }.map { |s, _, v| [s, v & 0xFF] }] }
      @rx = @queues[UART_RX]
      # 番地ごとの [[step, 値], ...] (step の順。同じ step なら後が勝つ)
      @levels = Hash.new { |h, k| h[k] = [] }
      stim.each { |st, a, v| @levels[a] << [st, v & MASK] if LEVEL_INPUTS.include?(a) }
      @caused = 0
      @psg_out = [] # 取り出したパケット (再起動でも捨てない。トレースに出す)
      reset(0)
    end

    # 電源を入れた時と watchdog の再起動: 全部を初めから (watchdog の印は残す)。UART の届いていたバイトは捨てる
    def reset(step)
      @regs = Hash.new(0)
      @rng = RNG_SEED
      @rp = step.zero? ? 0 : @rx.count { |s, _| s <= step }
      # I2C と SPI の返事の読んだ数。外のチップはリセットされないので、watchdog の再起動でも初めからにしない
      @qp ||= { I2C_RX => 0, SPI_RX => 0 }
      @pwm = {} # pin => [mHz, duty]
      @slots = Array.new(IRQ_SLOTS) # [pin, mask, debounce, 最後の時刻 (ms), 最後の事象]
      @queue = []
      @last = nil # 前の tick のピンの値
      @wdt = nil  # [期限 (µs), ms]
      psg_reset(0)
      @psg_ms = nil # 前の tick の仮想の時計の ms
      @unreg = 0
    end

    attr_reader :pwm

    # 取り出した (か、列を通さずに書いた) PSG のパケット [ms, {op, reg, val, arg}, aux] を取り出す (トレースの P 行)
    def take_psg
      out = @psg_out
      @psg_out = []
      out
    end

    # 命令を始める前。vtime はそれまでの仮想の時計 (µs)。watchdog の期限を過ぎていれば :reboot
    def tick(step, vtime)
      psg_tick(vtime / 1000)
      now = pin_levels(step)
      irq_events(now, (vtime & MASK) / 1000) if @last && @slots.any? # 時刻は C と同じく time_us_32() / 1000
      @last = now
      return nil unless @wdt && vtime >= @wdt[0]
      @caused = 1
      reset(step)
      :reboot
    end

    # PSG の列を初めから (C の reset_psg。sel が 0 なら止めた状態 = rb.buf が無い)
    def psg_reset(sel)
      @psg_sel = sel
      @psg_ring = [] # [遅延, {op, reg, val, arg}, aux]
      @psg_g = 0     # g_tick_ms
      @psg_due = false
      @psg_delay = 0
      @psg_aux = 0
    end

    # C は 1ms ごとの tick で g_tick_ms を進め、先頭の遅延が来たパケットを全部取り出す (空になったら g_tick_ms = 0)。
    # ここは命令の区切りごとに1つずつ取り出す (ms の境を越えた tick から、取り出せなくなるまで)。取り出した時刻は
    # C と同じ ms (まとめて進めた時は、遅延が来た ms = 今の ms - 残りの g)
    def psg_tick(ms)
      @psg_ms ||= ms
      if ms > @psg_ms
        @psg_g += ms - @psg_ms if @psg_sel != 0
        @psg_ms = ms
        @psg_due = true
      end
      return unless @psg_due && @psg_sel != 0
      if @psg_ring.empty?
        @psg_g = 0
        @psg_due = false
        return
      end
      delay, word, aux = @psg_ring[0]
      if delay > @psg_g
        @psg_due = false
        return
      end
      @psg_g -= delay
      @psg_ring.shift
      @psg_out << [ms - @psg_g, word, aux]
      @psg_g = 0 if @psg_ring.empty?
    end

    # RP2040 の gpio_irq_callback と同じ: ピンの事象を、そのピンで有効な mask の和で絞り、最初に重なる枠へ
    def irq_events(now, ms)
      @slots.compact.map { |sl| sl[0] }.uniq.sort.each do |pin|
        next if pin >= 32
        live = @slots.each_with_index.select { |sl, _| sl && sl[0] == pin }
        enabled = live.map { |sl, _| sl[1] }.reduce(0) { |m, x| m | x } # 同じピンの mask の和
        was = @last[pin]
        is = now[pin]
        ev = 0
        ev |= 1 if is == 0
        ev |= 2 if is == 1
        ev |= 4 if was == 1 && is == 0
        ev |= 8 if was == 0 && is == 1
        ev &= enabled
        next if ev.zero?
        live.each do |sl, i|
          next if (ev & sl[1]).zero?
          next if sl[2] > 0 && ((ms - sl[3]) & MASK) < sl[2] && ev == sl[4] # debounce
          sl[3] = ms & MASK
          sl[4] = ev
          @queue << [i + 1, ev] if @queue.size < IRQ_QUEUE - 1
          break
        end
      end
    end

    def level_input(addr, step)
      rows = @levels[addr]
      i = rows.bsearch_index { |st, _| st > step } || rows.size # step より後の最初の行
      i.zero? ? 0 : rows[i - 1][1]
    end

    # 32 本のピンの今の値
    def pin_levels(step)
      dir = @regs[GPIO_DIR]
      out = @regs[GPIO_OUT]
      od = @regs[GPIO_OD]
      low = level_input(GPIO_EXT_LOW, step)
      high = level_input(GPIO_EXT_HIGH, step)
      # 出力で駆動しているピン (open drain は 0 の時だけ)
      driven = dir & ~(od & out) & MASK
      # 離しているピン: 外から L > 外から H > pull up (pull down と両方なら down) > 0
      released = (~low & (high | (@regs[GPIO_PULLUP] & ~@regs[GPIO_PULLDOWN]))) & MASK
      ((out & driven) | (released & ~driven)) & MASK
    end

    # 応答する I2C の番地の k 番目の語 (刺激が無ければ既定)
    def present_word(k, step)
      rows = @levels[I2C_PRESENT + k]
      return I2C_PRESENT_DEFAULT[k] if rows.empty? || rows[0][0] > step
      level_input(I2C_PRESENT + k, step)
    end

    def rx_avail(step)
      @rx.count { |s, _| s <= step } - @rp
    end

    # 読む。vtime は仮想の時計 (µs)。知らない番地は nil。32bit のレジスタは符号付きに広げる (コアの Integer は 64bit)
    def read(addr, step, vtime)
      return vtime if addr == TIME_US
      return vtime / 1000 if addr == TIME_MS
      v = read32(addr, step, vtime)
      v.nil? ? nil : (v >= 0x8000_0000 ? v - 0x1_0000_0000 : v)
    end

    # 32bit のレジスタの値 (符号なし)
    def read32(addr, step, vtime)
      case addr
      when *REGS then @regs[addr]
      when GPIO_LEVEL then pin_levels(step)
      when GPIO_EXT_LOW, GPIO_EXT_HIGH then level_input(addr, step)
      when TIME_US_HI then (vtime >> 32) & MASK
      when UART_RX
        return MASK if rx_avail(step) <= 0 # -1
        b = @rx[@rp][1]
        @rp += 1
        b
      when UART_AVAIL then rx_avail(step)
      when PWM_FREQ, PWM_DUTY then (@pwm[@regs[PWM_SEL]] || [0, 0])[addr - PWM_FREQ]
      when PWM_RUNNING then @pwm.select { |_, (f, _)| f > 0 }.keys.sum { |p| 1 << p }
      when ADC_BASE...ADC_BASE + ADC_INPUTS then level_input(addr, step) & 0xFFF
      when IRQ_REGISTER
        i = @slots.index(nil)
        return MASK if i.nil?
        @slots[i] = [@regs[IRQ_PIN], @regs[IRQ_MASK] & 0xF, @regs[IRQ_DEBOUNCE], 0, 0]
        i + 1
      when IRQ_UNREG then @unreg
      when IRQ_EVENT
        return MASK if @queue.empty?
        id, ev = @queue.shift
        (id << 8) | ev
      when WDT_CAUSED then @caused
      when I2C_ACK
        a = @regs[I2C_ADDR] & 0x7F
        (present_word(a >> 5, step) >> (a & 31)) & 1
      when I2C_PRESENT...I2C_PRESENT + 4 then present_word(addr - I2C_PRESENT, step)
      when I2C_RX, SPI_RX
        q = @queues[addr]
        return 0xFF if q.count { |s, _| s <= step } <= @qp[addr]
        b = q[@qp[addr]][1]
        @qp[addr] += 1
        b
      when WDT_REMAIN then @wdt ? [@wdt[0] - vtime, 0].max & MASK : 0
      when PSG_FREE then @psg_sel.zero? ? 0 : PSG_SLOTS - 1 - @psg_ring.size
      when PSG_EMPTY then @psg_ring.empty? ? 1 : 0
      when PSG_SELECT then @psg_sel
      when RNG
        x = @rng
        x ^= (x << 13) & MASK
        x ^= x >> 17
        x ^= (x << 5) & MASK
        @rng = x
      end
    end

    # 書く。vtime は書いた時の仮想の時計 (µs)。レジスタでない番地 (UART_TX など) は何もしない (トレースの O 行には出る)
    def write(addr, value, vtime = 0)
      value &= MASK
      @regs[addr] = value if REGS.include?(addr)
      case addr
      when PWM_FREQ, PWM_DUTY
        return if @regs[PWM_SEL] >= 32 # ピンは 0..31
        cur = @pwm[@regs[PWM_SEL]] || [0, 0]
        cur = addr == PWM_FREQ ? [value, cur[1]] : [cur[0], value]
        @pwm[@regs[PWM_SEL]] = cur
      when IRQ_ID
        id = value
        if id >= 1 && id <= IRQ_SLOTS && @slots[id - 1]
          @slots[id - 1] = nil
          @unreg = 1
        else
          @unreg = 0
        end
      when WDT_ENABLE, WDT_REBOOT then @wdt = [vtime + value * 1000, value]
      when WDT_DISABLE then @wdt = nil
      when PSG_DELAY then @psg_delay = value
      when PSG_AUX then @psg_aux = value & 0xFFFF
      when PSG_PUSH
        @psg_ring << [@psg_delay, value, @psg_aux] if @psg_sel != 0 && @psg_ring.size < PSG_SLOTS - 1
      when PSG_EMPTY then @psg_ring.clear
      when PSG_SELECT then psg_reset(value)
      when PSG_DIRECT_REG then @psg_out << [(vtime / 1000) & MASK, (PSG_OP_DIRECT_REG << 24) | ((value & 0xFF00) << 8) | (value & 0xFF), 0]
      when PSG_DIRECT_MUTE then @psg_out << [(vtime / 1000) & MASK, (PSG_OP_DIRECT_MUTE << 24) | ((value & 0xFF00) << 8) | (value & 0xFF), 0]
      when WDT_FEED then @wdt = [vtime + @wdt[1] * 1000, @wdt[1]] if @wdt
      end
    end
  end
end
