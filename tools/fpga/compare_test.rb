require_relative "test_helper"
require_relative "compare"

class FpgaCompareTest < Minitest::Test
  include FpgaTestHelper

  REF = [
    "X 0 0 07", "W 0 1 3 00000001",
    "X 1 1 16", "O 1 0 3 00000001",
    format("X 2 2 %02x", FpgaIsa.op("SUB").num), "W 2 1 3 00000000",
    "X 3 3 76", "H 3 3"
  ].freeze

  def test_same_traces_pass
    r = FpgaCompare.compare(REF, REF.dup)
    assert r.ok
    assert_equal 1, r.io_count
    assert_equal "H 3 3", r.ending
  end

  def test_names_the_instruction_where_they_diverge
    sim = REF.dup
    sim[5] = "W 2 1 3 00000002"
    r = FpgaCompare.compare(REF, sim)
    # I/O は同じでもトレースがずれていれば落とすのではなく、合否は I/O で決める
    assert r.ok
    sim[7] = "E 3 3 76"
    r = FpgaCompare.compare(REF, sim)
    refute r.ok
    assert_match(/first difference at step 2, pc 2 \(SUB\)/, r.message)
  end

  def test_decode_values
    assert_equal(-1, FpgaCompare.decode(FpgaIsa::TAG_INT, 0xFFFF_FFFF))
    assert_nil FpgaCompare.decode(FpgaIsa::TAG_NIL, 0)
    assert_equal true, FpgaCompare.decode(FpgaIsa::TAG_TRUE, 0)
  end
end
