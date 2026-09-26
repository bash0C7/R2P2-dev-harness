# GC: ループで配列を作り捨て、長生きする配列・入れ子の配列・Proc が GC の後も正しいことを見る (有限)
table = [[1, 2], [3, 4]]
keep = []
scale = 3
times3 = proc { |v| v * scale }
200.times do |i|
  tmp = [i, i + 1, i + 2]
  pair = [tmp, [i]]
  keep << pair[0][1] if i % 25 == 0
end
$LED = keep.size
$LED = keep[3]
$LED = table[1][1]
$LED = times3.call(keep.last)
grow = []
300.times { |i| grow << i }
$LED = grow.size
$LED = grow[299]
$LED = keep.map { |x| x * 2 }.last
