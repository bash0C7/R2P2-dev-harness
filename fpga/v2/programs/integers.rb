# Integer: 64bit の境目、floor の除算と剰余、to_s
max = 9223372036854775807
min = -max - 1
puts max, min, min + 1, -max
puts 7 / 2, -7 / 2, 7 / -2, -7 / -2
puts 7 % 3, -7 % 3, 7 % -3, -7 % -3
puts 12 & 10, 12 | 3, 12 ^ 5
puts 100000 * 100000, 3000000000 * 3
i = 0
s = 0
while i < 100
  s += i * i
  i += 1
end
puts s
puts 1 < 2, 2 <= 1, 3 > 2, 3 >= 4, 5 == 5, 5 != 5
