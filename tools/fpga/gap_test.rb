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
    bin = rite([op("LOADL"), 1, 0, op("SSEND"), 1, 0, 1, op("SCLASS"), 2, op("STOP")], syms: %w[foo], pool: [:float])
    assert_equal ["Float literal", "method foo", "op SCLASS"], FpgaGap.blockers(bin)
  end

  # 組み込み・iterator・def したメソッドは理由にしない
  def test_supported_calls_are_not_blockers
    child = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")])
    bin = rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("SEND0"), 1, 1, op("STOP")], syms: %w[f abs], reps: [child])
    assert_equal [], FpgaGap.blockers(bin)
  end

  # attr_* が定義する名前と、クラスの本体の宣言 (include / private など) も理由にしない
  def test_attr_and_declarations_are_not_blockers
    bin = rite([op("LOADSYM"), 2, 0, op("SSEND"), 1, 1, 1, op("SSEND0"), 1, 2, op("SEND0"), 3, 0,
                op("LOADSYM"), 4, 3, op("SEND"), 3, 3, 1, op("SEND0"), 3, 4, op("STOP")],
               syms: %w[count attr_accessor private count= missing])
    assert_equal ["method missing"], FpgaGap.blockers(bin)
  end
end
