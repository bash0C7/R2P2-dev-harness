# frozen_string_literal: true

# fpga/tb/mrb_fpconv_tb.sv が読むベクタ (fpga/tb/mrb_fpconv_vectors.txt) を tools/fpga/fpconv.rb で作る。
# 1行 = 種類 (0 to_s / 1 format / 2 strtod) double の bit 変換の文字 精度 10の指数 桁 (16進) 期待の長さ 期待のバイト
# (16進、最後のバイトが先頭)。rake fpga:fpconv:vectors
require_relative "fpconv"

module FpgaFpconvVectors
  SPECIAL = [0.1 + 0.2, 1e20, 100.0, 1.5e-7, -0.0001, 1.0 / 3, 123456789.123, 1e15, 999999999999999.9, 5e-324, 1e-5, -12.5,
             0.0, -0.0, 1936846153033430.2, 1192192476070245.5, 1.7976931348623157e308, 2.2250738585072014e-308, 3348.05,
             -1840102016.2746506, 2.5, 0.5, 1e23, 9007199254740993.0].freeze

  module_function

  def random_value(rng)
    case rng.rand(4)
    when 0 then [rng.rand(1 << 64) & ~(0x7FF << 52) | (rng.rand(2047) << 52)].pack("Q").unpack1("D")
    when 1 then rng.rand * 10**rng.rand(-10..20)
    when 2 then rng.rand(1_000_000) / 100.0
    else rng.rand(1 << 53) * 2.0**rng.rand(-1100..970)
    end
  end

  def hex_bytes(str)
    str.empty? ? "0" : str.bytes.reverse.map { |b| format("%02x", b) }.join
  end

  def lines(seed: 7, count: 150)
    rng = Random.new(seed)
    vals = SPECIAL + Array.new(count) { random_value(rng) }
    out = []
    vals.each do |v|
      b = [v].pack("G").unpack1("Q>")
      bits = format("%016x", b)
      s = FpgaFloat.to_s(b)
      out << "0 #{bits} 0 0 0 0 #{s.bytesize} #{hex_bytes(s)}"
      %w[f e E g G].each do |c|
        p = rng.rand(0..20)
        next if c == "f" && v.abs > 1e60 # 桁が文字列の上限 (FBUF) を越える
        s = FpgaFloat.fmt(b, c, p)
        out << "1 #{bits} #{c.ord.to_s(16)} #{p} 0 0 #{s.bytesize} #{hex_bytes(s)}"
      end
      next unless v.finite? && v != 0
      t = format("%.#{rng.rand(1..25)}e", v.abs).sub("e+", "e")
      int, frac, exp = t.match(/\A(\d+)(?:\.(\d+))?e([-+]?\d+)\z/).captures
      d = (int + frac.to_s).to_i
      out << "2 #{format('%016x', FpgaFloat.strtod(t))} 0 0 #{exp.to_i - frac.to_s.size} #{d.to_s(16)} 0 0"
    end
    out
  end
end

if $PROGRAM_NAME == __FILE__
  path = ARGV[0] || File.expand_path("../../fpga/tb/mrb_fpconv_vectors.txt", __dir__)
  File.write(path, FpgaFpconvVectors.lines.join("\n") + "\n")
end
