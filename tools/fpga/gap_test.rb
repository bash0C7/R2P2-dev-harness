require_relative "test_helper"
require_relative "gap"

class FpgaGapTest < Minitest::Test
  include FpgaTestHelper

  def test_out_of_scope_is_hardware_the_board_lacks
    assert_equal "require socket", FpgaGap.out_of_scope("require 'socket'\n")
    assert_equal "uses TCPSocket", FpgaGap.out_of_scope("s = TCPSocket.new('a', 1)\n")
    assert_nil FpgaGap.out_of_scope("require 'gpio'\nrequire \"i2c\"\n")
  end

  # 最初の1つで止めず、止まる理由を全部挙げる
  def test_blockers_lists_every_reason
    bin = rite([op("STRING"), 1, 0, op("SSEND"), 1, 0, 1, op("HASH"), 2, 3, 0, op("STOP")], syms: %w[puts foo], plen: 1)
    assert_equal ["pool (strings / big integers)", "op STRING", "method puts", "op HASH"], FpgaGap.blockers(bin)
  end

  # 組み込み・iterator・def したメソッドは理由にしない
  def test_supported_calls_are_not_blockers
    child = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")])
    bin = rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("SEND0"), 1, 1, op("STOP")], syms: %w[f abs], reps: [child])
    assert_equal [], FpgaGap.blockers(bin)
  end
end
