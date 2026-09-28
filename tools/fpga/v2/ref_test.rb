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

  # 機械の状態は記憶の中 (計画 S2b): ref の CRuby 側の変数は、回路のレジスタ・cache・定数の番地の一覧 (Ref::CRUBY_STATE) だけ。
  # フレームは記憶の mrb_callinfo で、Ci は番地と、フレームの間変わらない欄の cache だけを持つ
  def test_machine_state_lives_in_memory
    out, ref = FpgaV2::Build.run_source("class A\n  def f(x)\n    x + 1\n  end\nend\nputs A.new.f(1)\n")
    assert_equal "2\n", out
    assert_equal [], ref.instance_variables - FpgaV2::Ref::CRUBY_STATE
    ci = ref.instance_variable_get(:@f)
    assert_equal [], ci.instance_variables - %i[@r @addr @proc @irep @bp]
    # ctx->ci は今のフレームの番地
    ctx = ref.r32(FpgaV2::Layout::IMG[:c] * 4)
    assert_equal ci.addr, ref.r32(ctx + FpgaV2::Layout::CTX_CI)
  end

  # 計画 S6-2: 空の配列は中身の番地 0、容量 0 (ary_new_capa(0) は malloc しない)。そこから伸ばす (ary_expand_capa の realloc(0, ..))、
  # 長さ 0 の写し (__fpga_copy の番地 0)、空同士の足し算と concat と splat が壊れない
  def test_empty_arrays_have_no_buffer
    src = "a = []\nb = [] + []\nc = []\nc.concat([])\nd = [*[]]\ne = []\ne << 1\ne.push(2, 3)\nf = [].dup\n" \
          "g = []\ng.unshift(4)\nputs a.size, b.size, c.size, d.size, e.inspect, f.size, g.inspect\n"
    out, ref = FpgaV2::Build.run_source(src)
    assert_equal "0\n0\n0\n0\n[1, 2, 3]\n0\n[4]\n", out
    assert_operator ref.stats[:array_alloc] + ref.stats[:op_ARRAY], :>, 0 # 空の配列は回路 (速い道) か firmware の ary_new_capa(0) が作る
  end

  # 実行時の定義: 後の def は、実行した時から効く (v1 は後の def が最初から勝っていた)
  def test_redefinition_takes_effect_when_executed
    out, = FpgaV2::Build.run_source("def f\n  1\nend\nputs f\ndef f\n  2\nend\nputs f\n")
    assert_equal "1\n2\n", out
  end
end
