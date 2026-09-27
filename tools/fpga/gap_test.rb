require_relative "test_helper"
require_relative "gap"

class FpgaGapTest < Minitest::Test
  include FpgaTestHelper

  def test_out_of_scope_is_hardware_the_board_lacks
    assert_equal "require socket", FpgaGap.out_of_scope("require 'socket'\n")
    assert_equal "uses TCPSocket", FpgaGap.out_of_scope("s = TCPSocket.new('a', 1)\n")
    assert_nil FpgaGap.out_of_scope("require 'gpio'\nrequire \"i2c\"\n")
  end

  # Picotest::Runner は host (CRuby) で走る係
  def test_picotest_runner_is_host_side
    assert_equal "host side: Picotest::Runner", FpgaGap.out_of_scope("require 'picotest'\nPicotest::Runner.run(dir)\n")
    assert_nil FpgaGap.out_of_scope("# Picotest::Runner が渡すのと同じ形\nrequire 'picotest'\n") # 注釈の中は数えない
  end

  # picotest のテストのファイルには Runner と同じ末尾 (test_* を順に呼んで JSON) を付ける
  def test_picotest_tail_calls_each_test
    tail = FpgaGap.picotest_tail("class ATest < Picotest::Test\n  def test_a\n  end\n  def helper\n  end\n  def test_b\n  end\nend\n")
    assert_match(/my_test = ATest\.new/, tail)
    assert_equal %w[test_a test_b], tail.scan(/^  my_test\.(test_\w+)$/).flatten
    assert_match(/puts JSON\.generate\(my_test\.result\)/, tail)
    assert_nil FpgaGap.picotest_tail("class A\nend\n")
  end

  # 最初の1つで止めず、止まる理由を全部挙げる (Float のリテラルはもう理由にならない)
  def test_blockers_lists_every_reason
    bin = rite([op("LOADL"), 1, 0, op("SSEND"), 1, 0, 1, op("UNDEF"), 0, op("STOP")], syms: %w[foo], pool: [:float])
    assert_equal ["method foo", "op UNDEF"], FpgaGap.blockers(bin)
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
