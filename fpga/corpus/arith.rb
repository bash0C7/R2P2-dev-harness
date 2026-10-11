# 整数演算・比較・nil/true/false を一通り通し、結果を $LED に順に出す (有限)
a = 300
b = -7
$LED = a + b
$LED = a - b
$LED = b - 1
$LED = b + 1
$LED = -1
x = nil
$LED = x ? 1 : 2
t = true
$LED = t ? 3 : 4
$LED = a > b ? 5 : 6
$LED = a <= b ? 7 : 8
$LED = b >= -7 ? 9 : 10
$LED = a == 300 ? 11 : 12
k = 40000
k -= 1
$LED = k
m = -200
$LED = m
until a < 290
  a -= 3
end
$LED = a
