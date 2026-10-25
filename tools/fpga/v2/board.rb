# v2 の板のモデル (Ruby コード、計画 S7-1: docs/superpowers/plans/2026-09-28-fpga-v2-s7-gems.md)。
# ref の mmio (layout.rb の MMIO_*) を受ける GPIO とタイマーと tick の割り込み。host の fpga の VM は同じモデルを
# firmware-patches/posix-board-{clock,gpio}.patch で持つ (両方を変える時は一緒に)。
#
# - 時刻は tick (TASK_TICK_UNIT ms) の数。WFI の書き込み (全 task が待つ時) だけ 1 tick 進む (D100)
# - ピンの値が変わると (時刻 ms, pin, 値) を列に足す。上限 (until_ms) を超える tick へ進む所で Ref::Halt を上げて止める
require_relative "layout"

module FpgaV2
  class Board
    include Layout
    class Error < StandardError; end

    # LED のピン (V4 で PERIDOT-Air の USER_LED[0] (PIN_105) に当てる。それまでは I/O 0〜27 の次)
    LED_PIN = 28
    MASK = (1 << GPIO_PINS) - 1

    attr_reader :events, :ticks

    def initialize(until_ms: nil)
      @until_ms = until_ms
      @out = 0
      @dir = 0
      @pull_up = 0
      @pull_down = 0
      @ticks = 0
      @irq = 0
      @events = []
    end

    def ms = @ticks * TASK_TICK_UNIT

    # ピンの値: 出力は latch、入力は pull down の時 0、ほかは 1 (D101)
    def levels = ((@dir & @out) | (~@dir & ~@pull_down)) & MASK

    def ld32(a)
      case a
      when MMIO_GPIO_OUT then @out
      when MMIO_GPIO_DIR then @dir
      when MMIO_GPIO_IN then levels
      when MMIO_GPIO_PULL_UP then @pull_up
      when MMIO_GPIO_PULL_DOWN then @pull_down
      when MMIO_TIMER_TICKS then @ticks & 0xFFFF_FFFF
      when MMIO_IRQ then @irq
      else raise Error, format("mmio read of 0x%08x", a)
      end
    end

    def st32(a, v)
      v &= 0xFFFF_FFFF
      case a
      when MMIO_GPIO_OUT then pins { @out = v & MASK }
      when MMIO_GPIO_DIR then pins { @dir = v & MASK }
      when MMIO_GPIO_PULL_UP then pins { @pull_up = v & MASK }
      when MMIO_GPIO_PULL_DOWN then pins { @pull_down = v & MASK }
      when MMIO_WFI then wfi
      when MMIO_IRQ then @irq &= ~v
      else raise Error, format("mmio write of 0x%08x", a)
      end
    end

    private

    def pins
      before = levels
      yield
      after = levels
      GPIO_PINS.times { |pin| @events << [ms, pin, (after >> pin) & 1] if ((before ^ after) >> pin).allbits?(1) }
    end

    # 割り込みを待つ: 次の tick まで時刻を進め、tick の割り込みを立てる
    def wfi
      raise Ref::Halt if @until_ms && (@ticks + 1) * TASK_TICK_UNIT > @until_ms

      @ticks += 1
      @irq |= MMIO_IRQ_TICK
    end
  end
end
