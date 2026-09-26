require_relative "test_helper"

class FpgaIsaTest < Minitest::Test
  include FpgaTestHelper

  def test_119_opcodes_in_ops_h_order
    assert_equal 119, FpgaIsa::ALL.size
    assert_equal "TABLE", FpgaIsa.op(0xF0).name # FPGA だけの命令は番号の外
    assert_equal 0, FpgaIsa.op("NOP").num
    assert_equal 118, FpgaIsa.op("STOP").num
  end

  def test_supported_is_a_subset
    FpgaIsa::SUPPORTED.each { |n| assert FpgaIsa::BY_NAME.key?(n), n }
  end

  def test_matches_vendor_ops_h
    skip "vendor/picoruby is not there" unless File.file?(OPS_H)
    from_h = File.read(OPS_H).scan(/^OPCODE\((\w+),\s*(\w+)\)/)
    assert_equal from_h, FpgaIsa::ALL
  end
end
