require "minitest/autorun"
require "fiddle"
require_relative "build"

# firmware の soft-float (fpga/firmware/float.rb、乖離表 D50) を参照で走らせ、CRuby の double (と libm) の結果とビットで比べる。
# 被演算子は乱数 (全部の指数)、近い値どうし、非正規化数、0、無限大、NaN、境界の値。NaN は NaN であることだけを比べる
# (NaN の中身は見える意味に無い。mruby は NaN を作るたびに通し番号を入れる)
class FpgaV2SoftFloatTest < Minitest::Test
  LIBM = Fiddle.dlopen(nil)
  D = Fiddle::TYPE_DOUBLE
  FLOOR = Fiddle::Function.new(LIBM["floor"], [D], D)
  CEIL = Fiddle::Function.new(LIBM["ceil"], [D], D)
  ROUND = Fiddle::Function.new(LIBM["round"], [D], D)
  TRUNC = Fiddle::Function.new(LIBM["trunc"], [D], D)
  FMOD = Fiddle::Function.new(LIBM["fmod"], [D, D], D)

  def self.bits(f) = [f].pack("d").unpack1("q")
  def self.flo(b) = [b].pack("q").unpack1("d")
  def bits(f) = self.class.bits(f)
  def flo(b) = self.class.flo(b)

  EDGE = [0.0, -0.0, 1.0, -1.0, 0.5, 1.5, 2.5, -2.5, 3.0, 0.1, 1e308, -1e308, Float::MAX, Float::MIN, 5e-324, -5e-324,
          2.2250738585072009e-308, 4.9e-322, Float::INFINITY, -Float::INFINITY, Float::NAN, 2.0**52, 2.0**53, 2.0**53 + 2,
          -(2.0**63), 2.0**63, 4503599627370495.5, 0.49999999999999994, 1e-310, 123456.789, -7.25].freeze

  def operands(rng, n)
    list = EDGE.map { |f| bits(f) }
    while list.size < n
      case rng.rand(5)
      when 0 then list << rng.rand(-(2**63)...(2**63)) # ビットの乱数 (全部の指数)
      when 1 then list << bits((rng.rand - 0.5) * 10.0**rng.rand(-20..20))
      when 2 then list << rng.rand(0...(2**52)) * (rng.rand(2).zero? ? 1 : -1) # 非正規化数
      when 3 then list << bits(rng.rand(-1000..1000).to_f + [0.0, 0.5, 0.25, 0.75].sample(random: rng))
      else list << bits(rng.rand * 2.0**rng.rand(-1080..1030))
      end
    end
    list
  end

  # pairs の各組に firmware の helper を当てた結果 (Integer の並び)
  def run_fw(helper, xs, ys = nil)
    src = +"xs = [#{xs.join(', ')}]\n"
    src << "ys = [#{ys.join(', ')}]\n" if ys
    src << "i = 0\nwhile i < xs.size\n"
    src << (ys ? "  puts #{helper}(xs[i], ys[i])\n" : "  puts #{helper}(xs[i])\n")
    src << "  i += 1\nend\n"
    out, = FpgaV2::Build.run_source(src, max_steps: 60_000_000)
    out.lines.map(&:to_i)
  end

  def check(name, got, want, args)
    got.zip(want, args).each do |g, w, a|
      if flo(w).nan?
        assert flo(g).nan?, "#{name}#{a.map { |x| flo(x) }.inspect}: want NaN, got #{flo(g)}"
      else
        assert_equal w, g, "#{name}#{a.map { |x| flo(x) }.inspect}: want #{flo(w)} (#{w}), got #{flo(g)} (#{g})"
      end
    end
  end

  def binary(helper, seed, n)
    rng = Random.new(seed)
    xs = operands(rng, n)
    ys = operands(rng, n).shuffle(random: rng)
    # 近い値どうし (桁落ちと丸めの境い目)
    xs.first(n / 4).each_with_index { |x, k| ys[EDGE.size + k] = x + rng.rand(-3..3) if flo(x).finite? }
    ys.map! { |y| y.clamp(-(2**63), 2**63 - 1) }
    got = run_fw(helper, xs, ys)
    want = xs.zip(ys).map { |x, y| bits(yield(flo(x), flo(y))) }
    check(helper, got, want, xs.zip(ys))
  end

  def unary(helper, seed, n)
    xs = operands(Random.new(seed), n)
    got = run_fw(helper, xs)
    want = xs.map { |x| yield(x) }
    check(helper, got, want, xs.map { |x| [x] })
  end

  def test_add = binary("__fpga_f64_add", 1, 400) { |a, b| a + b }
  def test_sub = binary("__fpga_f64_sub", 2, 400) { |a, b| a - b }
  def test_mul = binary("__fpga_f64_mul", 3, 400) { |a, b| a * b }
  def test_div = binary("__fpga_f64_div", 4, 400) { |a, b| a / b }
  def test_fmod = binary("__fpga_f64_fmod", 5, 300) { |a, b| FMOD.call(a, b) }
  def test_floor = unary("__fpga_f64_floor", 6, 200) { |x| bits(FLOOR.call(flo(x))) }
  def test_ceil = unary("__fpga_f64_ceil", 7, 200) { |x| bits(CEIL.call(flo(x))) }
  def test_round = unary("__fpga_f64_round", 8, 200) { |x| bits(ROUND.call(flo(x))) }
  def test_trunc = unary("__fpga_f64_trunc", 9, 200) { |x| bits(TRUNC.call(flo(x))) }

  # (double)i: 64bit の整数の全域
  def test_from_int
    rng = Random.new(10)
    xs = [0, 1, -1, 2**53, 2**53 + 1, 2**53 + 3, 2**62 + 2**10 + 1, 2**63 - 1, -(2**63), -(2**63) + 1] +
         Array.new(300) { rng.rand(-(2**63)...(2**63)) >> rng.rand(0..62) }
    got = run_fw("__fpga_f64_from_int", xs)
    assert_equal xs.map { |i| bits(i.to_f) }, got
  end

  # (mrb_int)f: mrb_int に入る有限の値を 0 に向けて切る
  def test_to_int
    rng = Random.new(11)
    xs = operands(rng, 400).select { |b| f = flo(b); f.finite? && f >= -(2.0**63) && f < 2.0**63 }
    got = run_fw("__fpga_f64_to_int", xs)
    assert_equal xs.map { |b| flo(b).truncate }, got
  end

  # pow (指数が整数の時だけ写した、D50): 正確な有理数の累乗を最近接の偶数へ丸めたものと同じ。特別な値 (0、無限大、NaN、±1) も
  def test_pow
    rng = Random.new(13)
    pairs = [[2.0, 63.0], [2.0, -1.0], [2.2, 0.0], [10.0, 23.0], [10.0, -5.0], [3.0, 40.0], [-2.0, 3.0], [-8.0, -3.0],
             [0.0, -1.0], [-0.0, -3.0], [-0.0, 3.0], [Float::INFINITY, -2.0], [-Float::INFINITY, 3.0], [1.0, Float::NAN],
             [Float::NAN, 0.0], [-1.0, Float::INFINITY], [0.5, -Float::INFINITY], [1.5, 1e300], [0.9, 2.0**62], [5e-324, 2.0],
             [1.0000001, 1_000_000.0], [-3.0, 1e20]]
    120.times { pairs << [(rng.rand - 0.5) * 10.0**rng.rand(-3..3), rng.rand(-40..40).to_f] }
    xs = pairs.map { |x, _| bits(x) }
    ys = pairs.map { |_, y| bits(y) }
    got = run_fw("__fpga_f64_pow", xs, ys)
    want = pairs.map do |x, y|
      next bits(x**y) unless x.finite? && y.finite? && !x.zero? && y.abs <= 64 # 特別な値と大きな指数は libm
      bits((x.to_r**y.to_i).to_f) # 正確な値を丸める
    end
    check("__fpga_f64_pow", got, want, xs.zip(ys))
  end

  # 比べる: -1、0、1、NaN なら 2
  def test_cmp
    binary_cmp = lambda do |a, b|
      next 2 if a.nan? || b.nan?
      a < b ? -1 : (a > b ? 1 : 0)
    end
    rng = Random.new(12)
    xs = operands(rng, 400)
    ys = operands(rng, 400).shuffle(random: rng)
    xs.first(80).each_with_index { |x, k| ys[k] = x }
    got = run_fw("__fpga_f64_cmp", xs, ys)
    assert_equal xs.zip(ys).map { |x, y| binary_cmp.(flo(x), flo(y)) }, got
  end
end
