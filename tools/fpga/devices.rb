# CPU コアの周りのデバイス (GPIO、時間、UART、RNG) の参照モデル。docs/spec.md §10「デバイス (P5)」。
#
# コアは primitive の __io_read(addr) / __io_write(addr, value) でデバイスのレジスタを読み書きする (16bit の番地、
# 値は 32bit の Integer)。RTL (fpga/rtl/mrb_dev.sv) と参照インタプリタ (ref_vm.rb) と、CRuby での突き合わせ
# (oracle.rb が __io_read / __io_write をこのモデルで定義する) が同じ形で動く。
#
# 外からの入力は刺激 ([step, 番地, 値]) で与える: GPIO の EXT_LOW / EXT_HIGH はその step からの値 (最後が勝つ)、
# UART の RX は1行が1バイトで、その step から読める (届いた順)。
module FpgaDevices
  GPIO_DIR      = 0x100 # 1 = 出力
  GPIO_OUT      = 0x101 # 出力の値
  GPIO_PULLUP   = 0x102
  GPIO_PULLDOWN = 0x103
  GPIO_OD       = 0x104 # open drain (出力の 1 は離す)
  GPIO_LEVEL    = 0x105 # ピンの今の値 (読むだけ)
  GPIO_EXT_LOW  = 0x106 # 外から L に落としているピン (刺激)
  GPIO_EXT_HIGH = 0x107 # 外から H にしているピン (刺激)
  TIME_US       = 0x110 # 仮想の時計 (µs) の下位 32bit: 始めた命令の数 + sleep した時間
  TIME_US_HI    = 0x111
  TIME_MS       = 0x112 # 仮想の時計 / 1000 の下位 32bit
  UART_TX       = 0x120 # 書くと1バイト送る
  UART_RX       = 0x121 # 読むと受けた1バイト (無ければ -1)
  UART_AVAIL    = 0x122 # 受けて読んでいないバイトの数
  UART_BAUD     = 0x123 # 書くだけ (シミュレーションでは意味を持たない)
  RNG           = 0x130 # 読むたびに xorshift32 の次の値
  RNG_SEED      = 2_463_534_242
  # 刺激で与える番地 (レベル)
  LEVEL_INPUTS = [GPIO_EXT_LOW, GPIO_EXT_HIGH].freeze
  REGS = [GPIO_DIR, GPIO_OUT, GPIO_PULLUP, GPIO_PULLDOWN, GPIO_OD].freeze
  MASK = 0xFFFF_FFFF

  def self.device?(addr)
    addr >= 0x100
  end

  # 1台分の状態
  class Bank
    attr_reader :regs

    # stim: [[step, addr, value], ...] (FpgaCompare.sort_stim の順)
    def initialize(stim = [])
      @regs = Hash.new(0)
      @rng = RNG_SEED
      @rx = stim.select { |_, a, _| a == UART_RX }.map { |s, _, v| [s, v & 0xFF] }
      @rp = 0
      @levels = stim.select { |_, a, _| LEVEL_INPUTS.include?(a) }
    end

    def level_input(addr, step)
      v = 0
      @levels.each { |s, a, val| v = val & MASK if a == addr && s <= step }
      v
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

    def rx_avail(step)
      @rx.count { |s, _| s <= step } - @rp
    end

    # 読む。vtime は仮想の時計 (µs)。知らない番地は nil
    def read(addr, step, vtime)
      case addr
      when *REGS then @regs[addr]
      when GPIO_LEVEL then pin_levels(step)
      when GPIO_EXT_LOW, GPIO_EXT_HIGH then level_input(addr, step)
      when TIME_US then vtime & MASK
      when TIME_US_HI then (vtime >> 32) & MASK
      when TIME_MS then (vtime / 1000) & MASK
      when UART_RX
        return MASK if rx_avail(step) <= 0 # -1
        b = @rx[@rp][1]
        @rp += 1
        b
      when UART_AVAIL then rx_avail(step)
      when RNG
        x = @rng
        x ^= (x << 13) & MASK
        x ^= x >> 17
        x ^= (x << 5) & MASK
        @rng = x
      end
    end

    # 書く。レジスタでない番地 (UART_TX など) は何もしない (書いたことはトレースの O 行に出る)
    def write(addr, value)
      @regs[addr] = value & MASK if REGS.include?(addr)
    end
  end
end
