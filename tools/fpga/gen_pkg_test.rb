require_relative "test_helper"
require_relative "gen_pkg"
require_relative "corpus"

class FpgaGenPkgTest < Minitest::Test
  include FpgaTestHelper

  def test_committed_package_is_current
    assert FpgaGenPkg.current?, "fpga/rtl/mrb_pkg.sv is stale. Run `rake fpga:gen`"
  end

  def test_package_lists_every_supported_op
    FpgaIsa::SUPPORTED.each { |n| assert_includes FpgaGenPkg.render, "OP_#{n} " }
  end

  def test_corpus_is_current
    skip "mrbc / picoruby are not built (vendor/picoruby)" unless File.executable?(MRBC) && File.executable?(PICORUBY)
    assert_empty FpgaCorpus.stale(MRBC, PICORUBY), "run `rake fpga:corpus`"
  end
end
