require_relative "test_helper"
require_relative "emu"

class FpgaEmuTest < Minitest::Test
  include FpgaTestHelper

  E = FpgaEmu::Event

  def test_scale_keeps_at_least_ten_cycles_per_step
    assert_equal [10, 100], FpgaEmu.scale(1000)
    assert_equal [20, 10], FpgaEmu.scale(200)
    assert_equal [20, 1], FpgaEmu.scale(20)
    assert_equal [1000, 1], FpgaEmu.scale(1000, fast: false)
  end

  def test_steps_for_covers_the_time_window
    # 1000 ms x 50MHz / (2 cycle x CE_DIV 1000) = 25000 step
    assert_operator FpgaEmu.steps_for(1000, 1000), :>=, 25_000
  end

  def test_ref_pin_sequence_dedups_and_uses_ruby_truthiness_for_leds
    int = FpgaIsa::TAG_INT
    trace = ["O 0 0 #{int} 00000000", "O 1 0 #{int} 00000001", "O 2 0 #{int} 00000005",
             "O 3 0 #{FpgaIsa::TAG_NIL} 00000000", "O 4 1 #{FpgaIsa::TAG_TRUE} 00000000"]
    assert_equal [false, true, false], FpgaEmu.ref_pin_sequence(trace, 0)
    assert_equal [false, true], FpgaEmu.ref_pin_sequence(trace, 1)
  end

  def test_check_against_ref_accepts_a_prefix_and_rejects_a_mismatch
    trace = ["O 0 0 3 00000001", "O 9 0 3 00000000", "O 18 0 3 00000001"]
    events = [E.new(0, "LED", 0), E.new(0, "LED2", 0), E.new(10, "LED", 1), E.new(20, "LED", 0)]
    assert FpgaEmu.check_against_ref(events, trace, 12).all?(&:first)
    # 窓の中にもう1回あるはずの変化が無い (LED が点きっぱなし) のは不一致
    refute FpgaEmu.check_against_ref(events[0, 3], trace, 20).first.first
    events << E.new(30, "LED", 0)
    refute FpgaEmu.check_against_ref(events, trace, 30).first.first
  end

  def test_periods_skip_the_first_interval_after_reset
    events = [E.new(0, "LED", 0), E.new(10, "LED", 1), E.new(110, "LED", 0), E.new(210, "LED", 1)]
    assert_in_delta 0.0001, FpgaEmu.periods(events)["LED"], 1e-9
    assert_nil FpgaEmu.periods(events)["LED2"]
  end
end
