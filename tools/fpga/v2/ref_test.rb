require "minitest/autorun"
require "open3"
require_relative "build"

# v2 の参照 + firmware で fpga/v2/programs/*.rb を走らせ、host の PicoRuby と出力が同じかを見る (正しさの関所、計画 V2)
class FpgaV2RefTest < Minitest::Test
  PROGRAMS = Dir[File.join(FpgaV2::Build::ROOT, "fpga/v2/programs/*.rb")].sort

  def setup
    skip "host の picoruby が無い (rake fpga:picoruby)" unless File.executable?(FpgaConverter.default_picoruby)
  end

  PROGRAMS.each do |path|
    name = File.basename(path, ".rb")
    define_method("test_#{name}_matches_host") do
      host, st = Open3.capture2(FpgaConverter.default_picoruby, path)
      assert st.success?, "host failed on #{name}"
      out, ref = FpgaV2::Build.run_source(File.read(path))
      assert_equal host.b, out, "#{name}: v2 reference output differs from host PicoRuby"
      assert_operator ref.stats[:trap], :>, 0 # 探索の外れは firmware の罠で解く
      assert_operator ref.stats[:mcache_hit], :>, 0
    end
  end

  # 実行時の定義: 後の def は、実行した時から効く (v1 は後の def が最初から勝っていた)
  def test_redefinition_takes_effect_when_executed
    out, = FpgaV2::Build.run_source("def f\n  1\nend\nputs f\ndef f\n  2\nend\nputs f\n")
    assert_equal "1\n2\n", out
  end
end
