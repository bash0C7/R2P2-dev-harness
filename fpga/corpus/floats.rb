# Float: リテラル、四則と %・**、Integer との混ざった演算と比較、表示 (最短表記)、丸め、変換、format、Math
a = 0.1 + 0.2
p a
p 1.0 / 3, 2.0 / 3, 1e20, 1e16, 1e15, 123456789.123, -0.0, 1.5e-7, 100.0, 1e-4, 1e-5
p 1.0 / 0, -1.0 / 0, (0.0 / 0).nan?
p 7 / 2.0, 7.0 / 2, 3 + 0.5, 3 * 1.5, 10 - 0.25, 2**0.5, 2.0**10
p 7.5 % 2, -7.5 % 2, 7.5 % -2, 7 % 2.5
begin
  5.0 % 0.0
rescue ZeroDivisionError => e
  puts e.message
end
p 7.5.divmod(2), -7.5.divmod(2), 1.0.divmod(0.3)
p 1 == 1.0, 1.0 == 1, 2 < 2.5, 2.5 > 3, 1.0 <=> 2, 3 <=> 2.5, 1.0.eql?(1), [1.5, 2] == [1.5, 2.0]
p 3.7.round, 3.2.ceil, 3.7.floor, -3.5.round, 2.5.round, -2.5.round, 3.14159.round(2), 2.675.round(2), 1234.5.round(-2)
p 3.99.to_i, -3.99.to_i, 3.7.truncate, 12.34.floor(1), 12.34.ceil(1), -0.4.round
p 10.to_f, 3.fdiv(4), "3.25".to_f, " -1.5e3xyz".to_f, "abc".to_f, "1_000.5".to_f, Float("2.5"), Float(3)
p 0.1 * 3, 1.1 * 1.1, 100.0 / 3.0, 1.0e+30 * 1.0e+30, 2.0**-1074
puts 3.14, 2.0, 1e100
puts format("%.2f %.3e %g %8.3f|%-8.2f|%+.1f", 3.14159, 1234.5678, 0.0001, 2.5, 2.5, 2.25)
p Math.sqrt(2), Math.sin(0.5), Math.cos(1), Math.atan2(1, 2), Math.log(10), Math.log(8, 2), Math.log10(1000), Math.exp(1), Math.hypot(3, 4)
p Math::PI, Math::E
s = 0.0
1.0.step(2.0, 0.25) { |x| s += x }
p s
xs = []
1.step(2, 0.5) { |x| xs << x }
p xs
p [3.5, 1.25, 2.0].sort, [3.5, 1.25, 2.0].max
p 1.5.to_s, 2.0.inspect, 1e9.to_i, 1.5.floor.class, 1.5.class, 1.5.is_a?(Float)
begin
  Math.sqrt(-1)
rescue Math::DomainError => e
  puts e.message
end
begin
  (0.0 / 0).to_i
rescue FloatDomainError => e
  puts e.message
end
