require "minitest/autorun"
require_relative "reset"

class ResetTest < Minitest::Test
  class FakeSerial
    attr_reader :calls

    def initialize
      @calls = []
    end

    def dtr=(v); @calls << [:dtr=, v]; end
    def rts=(v); @calls << [:rts=, v]; end
  end

  def test_pulse_drives_dtr_low_then_rts_high_then_low
    sp = FakeSerial.new
    slept = []
    Reset.pulse(sp, sleep_fn: ->(seconds) { slept << seconds })
    assert_equal [[:dtr=, 0], [:rts=, 1], [:rts=, 0]], sp.calls
    assert_equal [Reset::PULSE_SECONDS], slept
  end
end
