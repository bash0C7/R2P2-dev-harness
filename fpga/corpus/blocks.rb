# ブロック: times / upto / downto / loop、外側の変数、break (値つき)、next、入れ子、メソッドの中のブロック (有限)
sum = 0
4.times { |i| sum += i }
$LED = sum

1.upto(3) { |q| $LED = q * 10 }
3.downto(1) { |q| $LED2 = q }

k = 0
r = loop do
  k += 1
  break k * 2 if k > 4
end
$LED = r

5.times do |j|
  next if j.odd?
  $LED2 = j
end

# 入れ子: 内側のブロックから2つ外の変数を触る
total = 0
2.times do |a|
  3.times do |b|
    total += a * 10 + b
  end
end
$LED = total

def count_even(n)
  c = 0
  n.times { |i| c += 1 if i.even? }
  c
end
$LED = count_even(7)

def twice(x)
  x * 2
end
acc = 0
3.times { |i| acc += twice(i) }
$LED = acc

# 引数を取らないブロック、返り値 (times は受け手を返す)
$LED = 3.times { }
