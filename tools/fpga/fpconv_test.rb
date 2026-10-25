# frozen_string_literal: true

require "minitest/autorun"
require_relative "fpconv"
require_relative "fpconv_vectors"

# FpgaFloat (回路の Float と10進の変換と同じアルゴリズム) を CRuby の Float#to_s / format / Float() と突き合わせる
class FpgaFloatTest < Minitest::Test
  def bits(f)
    [f].pack("G").unpack1("Q>")
  end

  def values(seed, n)
    rng = Random.new(seed)
    (FpgaFpconvVectors::SPECIAL + Array.new(n) { FpgaFpconvVectors.random_value(rng) }).select(&:finite?).flat_map { |v| [v, -v] }
  end

  def test_to_s_is_ruby_float_to_s
    values(1, 3000).each { |v| assert_equal v.to_s, FpgaFloat.to_s(bits(v)), v.inspect }
    assert_equal "NaN", FpgaFloat.to_s(bits(Float::NAN))
    assert_equal "-Infinity", FpgaFloat.to_s(bits(-Float::INFINITY))
  end

  # C の printf と同じく正確に丸める。CRuby の format はまれに正しく丸めない (3348.05 の %.5g が 3348.0。
  # 3348.05 の double は 3348.0500000000001818... なので 3348.1 が正しい) ので、違ったら真の値に近い方が正しいとする
  def test_fmt_is_printf
    rng = Random.new(2)
    values(3, 1500).each do |v|
      %w[f e E g G].each do |c|
        next if c == "f" && v.abs > 1e60
        p = rng.rand(0..20)
        want = format("%.#{p}#{c}", v)
        got = FpgaFloat.fmt(bits(v), c, p)
        next if got == want
        assert_operator (v.to_r - Rational(got)).abs, :<, (v.to_r - Rational(want)).abs, "%.#{p}#{c} #{v.inspect}: #{got} vs #{want}"
      end
    end
    assert_equal "3348.1", FpgaFloat.fmt(bits(3348.05), "g", 5)
    assert_equal "-0.000", FpgaFloat.fmt(bits(-0.0), "f", 3)
  end

  def test_strtod_is_nearest
    rng = Random.new(4)
    values(5, 1500).each do |v|
      [v.to_s.sub("e+", "e"), format("%.#{rng.rand(1..30)}e", v)].each do |t|
        assert_equal bits(Float(t)), FpgaFloat.strtod(t), t
      end
    end
    # 桁が多くても指数で打ち切る所の前後
    %w[1e-324 3e-324 2.4703282292062328e-324 2.4703282292062327e-324 1.7976931348623158e308 1.7976931348623159e308
       0.0000000000000000000000000000000000000000001e-280 123456789012345678901234567890e-350 1e309 0e999].each do |t|
      assert_equal bits(Float(t)), FpgaFloat.strtod(t), t
    end
  end

  # fpga/tb/mrb_fpconv_vectors.txt は rake fpga:fpconv:vectors の出力のまま
  def test_vectors_are_fresh
    path = File.expand_path("../../fpga/tb/mrb_fpconv_vectors.txt", __dir__)
    assert_equal FpgaFpconvVectors.lines.join("\n") + "\n", File.read(path), "run `rake fpga:fpconv:vectors`"
  end
end
