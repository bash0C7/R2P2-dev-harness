# yield、&blk、proc、block_given?、ブロックからの break / return、入れ子のブロックから外側の変数 (有限)
def each_twice(n)
  i = 0
  while i < n
    yield i
    yield i
    i += 1
  end
end

def with_blk(&blk)
  blk.call(5)
end

def maybe
  if block_given? then yield else 0 end
end

def find_first(limit)
  limit.times do |i|
    return i if i * i > 10
  end
  -1
end

def repeat(n)
  n.times { |i| yield i }
end

t = 0
each_twice(2) { |x| t += x }
$LED = t
$LED = with_blk { |v| v * 2 }
$LED = maybe
$LED = maybe { 9 }
pr = proc { |z| z + t }
$LED = pr.call(1)
$LED = find_first(10)
$LED = find_first(2)
r = each_twice(5) { |x| break x * 100 if x == 3 }
$LED = r
acc = 0
repeat(3) { |i| repeat(2) { |j| acc += i * 10 + j } }
$LED = acc
add = proc { |p, q| p + (q || 0) }
$LED = add.call(4, 3)
$LED = add.call(4)
