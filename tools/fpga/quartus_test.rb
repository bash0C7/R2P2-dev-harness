require_relative "test_helper"
require_relative "converter"
require_relative "quartus"
require "tmpdir"

class FpgaQuartusTest < Minitest::Test
  include FpgaTestHelper

  def hex
    File.join(CORPUS, "blink.hex")
  end

  def test_rom_hex_fills_the_whole_rom_with_ones
    lines = FpgaQuartus.rom_hex(hex).lines(chomp: true)
    assert_equal FpgaQuartus::ROM_DEPTH, lines.size
    assert_equal File.readlines(hex, chomp: true).first, lines.first
    assert_equal "ffffffffffff", lines.last
  end

  def test_rom_hex_rejects_programs_larger_than_the_rom
    assert_raises(ArgumentError) { FpgaQuartus.rom_hex(hex, depth: 4) }
  end

  def test_sources_put_the_package_first_and_leave_out_test_circuits
    names = FpgaQuartus.sources.map { |p| File.basename(p) }
    assert_equal %w[mrb_fpconv_pkg.sv mrb_pkg.sv], names.first(2)
    assert_includes names, "peridot_air_top.sv"
    refute_includes names, "counter8.sv"
  end

  def test_project_is_self_contained
    Dir.mktmpdir do |dir|
      FpgaQuartus.write_project(dir, hex, ce_div: 250)
      qsf = File.read(File.join(dir, "#{FpgaQuartus::PROJECT}.qsf"))
      assert_includes qsf, "set_location_assignment PIN_105 -to USER_LED[0]"
      assert_includes qsf, "set_global_assignment -name SYSTEMVERILOG_FILE src/mrb_core.sv"
      assert_includes qsf, "set_parameter -name CE_DIV 250"
      assert_includes qsf, "set_parameter -name ROM_FILE \"rom.hex\""
      FpgaQuartus.sources.each { |s| assert File.file?(File.join(dir, "src", File.basename(s))) }
      assert File.file?(File.join(dir, "rom.hex"))
      assert File.file?(File.join(dir, "peridot_air.sdc"))
    end
  end
end
