# Hash、Range、case / when、Array と Enumerable のメソッド (プレリュード)。結果は console と $LED に
h = { "a" => 1, b: 2 }
h["c"] = 3
h[:b] += 10
p h, h.size, h.keys, h.values, h[:zz], h.fetch("a"), h.key?("c"), h.dig(:b)
h.each { |k, v| puts "#{k}=#{v}" }
p h.map { |k, v| v * 2 }, h.select { |k, v| v > 2 }, h.to_a, h.min_by { |k, v| v }
h.delete("a")
p h, h.merge({ d: 4 }), h.sort_by { |k, v| -v }.first
counts = Hash.new(0)
%w[x y x z x].each { |w| counts[w] += 1 }
p counts, counts.max_by { |k, v| v }
g = Hash.new { |hash, k| hash[k] = k * 2 }
p g[5], g
r = (1..5)
p r, r.to_a, (1...5).to_a, r.sum, r.include?(3), (1...5).include?(5), r.map { |x| x * x }, r.select { |x| x.even? }
$LED = (1..10).sum
$LED = r.inject { |s, x| s * x }
$LED = r.reduce(0) { |s, x| s + x }
$LED = (3..7).size
def kind(x)
  case x
  when 0 then "zero"
  when 1..9 then "small"
  when Integer then "big"
  when "hi", "hello" then "greeting"
  when nil then "nil"
  else "other"
  end
end
puts kind(0), kind(5), kind(99), kind("hi"), kind(nil), kind(:x)
a = [5, 3, 8, 1, 9, 2]
p a.sort, a.sort { |x, y| y <=> x }, a.sort_by { |x| -x }, a.min, a.max, a.sum, a.reverse
p a.select { |x| x.odd? }
p a[1, 3], a[2..], a[-2..-1], a[1...3], a.first(2), a.last(2), a.take(3), a.drop(4)
a.each_slice(4) { |s| p s }
p a.include?(8), a.index(8), a.count { |x| x.even? }
b = [1, 2, 2, 3, 3, 3]
p b.uniq, b.tally, b.group_by { |x| x.odd? }, b.partition { |x| x.odd? }
p [[1, 2], [3, 4]].to_h, [1, [2, [3, [4]]]].flatten, [1, nil, 2].compact, [3, 1] + [2], [1, 2, 3] - [2]
p [1, 2, 3].zip([4, 5, 6]), [1, 2, 3].each_with_object([]) { |x, m| m << x * 3 }, Array.new(3) { |i| i * i }
c = [1, 2, 3]
c.push(4, 5)
c.unshift(0)
c.insert(2, 9)
c.delete(9)
c.delete_at(0)
p c, c.shift, c, c.pop, c
p 2**10, 17.divmod(5), 12.gcd(18), 10.digits, 5.between?(1, 9), 15.clamp(1, 10)
