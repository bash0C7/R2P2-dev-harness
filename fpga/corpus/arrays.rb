# 配列: リテラル、添字 (負も)、代入 (伸ばす)、<< / push / pop、size / first / last / empty? / include?、
# each / each_with_index / map、入れ子、定数の配列 (有限)
a = [3, 1, 4]
a << 1
a.push(5)
$LED = a[0]
$LED = a[-1]
a[1] = 9
$LED = a.size
$LED = a.first
$LED = a.last
$LED = a.pop
$LED = a.length
$LED = a.empty?
$LED = [].empty?
$LED = a.include?(9)
$LED = a.include?(7)
$LED = a[10]
b = []
a.each { |x| b << x * 2 }
$LED = b[3]
a.each_with_index { |x, i| $LED2 = x + i }
c = a.map { |x| x + 1 }
$LED = c[2]
$LED = c.size
TABLE = [10, 20, 30]
$LED = TABLE[1]
m = [[1, 2], [3]]
$LED = m[1][0]
m[0][5] = 7
$LED = m[0].size
$LED = m[0][3]
sum = 0
[1, 2, 3, 4].each { |v| sum += v }
$LED = sum
