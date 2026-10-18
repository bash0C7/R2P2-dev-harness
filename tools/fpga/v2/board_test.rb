require "minitest/autorun"
require_relative "ref"

# 板のモデル (board.rb) のレジスタとピンの列 (計画 S7-1)。host の側 (firmware-patches/posix-board-*.patch) と同じ決まり
class FpgaV2BoardTest < Minitest::Test
  L = FpgaV2::Layout

  def test_pin_levels_follow_dir_out_and_pulls
    b = FpgaV2::Board.new
    assert_equal FpgaV2::Board::MASK, b.ld32(L::MMIO_GPIO_IN) # 浮いた入力は 1
    b.st32(L::MMIO_GPIO_DIR, 1 << 5)
    assert_equal 0, (b.ld32(L::MMIO_GPIO_IN) >> 5) & 1 # 出力で latch 0
    b.st32(L::MMIO_GPIO_OUT, 1 << 5)
    assert_equal 1, (b.ld32(L::MMIO_GPIO_IN) >> 5) & 1
    b.st32(L::MMIO_GPIO_PULL_DOWN, 1 << 6)
    assert_equal 0, (b.ld32(L::MMIO_GPIO_IN) >> 6) & 1 # pull down の入力は 0
    assert_equal [[0, 5, 0], [0, 5, 1], [0, 6, 0]], b.events
  end

  def test_wfi_advances_one_tick_and_raises_the_tick_irq
    b = FpgaV2::Board.new
    b.st32(L::MMIO_WFI, 1)
    assert_equal 1, b.ld32(L::MMIO_TIMER_TICKS)
    assert_equal L::TASK_TICK_UNIT, b.ms
    assert_equal L::MMIO_IRQ_TICK, b.ld32(L::MMIO_IRQ)
    b.st32(L::MMIO_IRQ, L::MMIO_IRQ_TICK)
    assert_equal 0, b.ld32(L::MMIO_IRQ)
  end

  def test_stops_before_a_tick_past_the_limit
    b = FpgaV2::Board.new(until_ms: 2 * L::TASK_TICK_UNIT)
    2.times { b.st32(L::MMIO_WFI, 1) }
    assert_raises(FpgaV2::Ref::Halt) { b.st32(L::MMIO_WFI, 1) }
    assert_equal 2, b.ticks
  end

  def test_unknown_register_is_an_error
    assert_raises(FpgaV2::Board::Error) { FpgaV2::Board.new.ld32(L::MMIO_BASE + 0x100) }
  end
end
