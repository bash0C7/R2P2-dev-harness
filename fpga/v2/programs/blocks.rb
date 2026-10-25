# ブロック (計画 S4-1): yield、局所変数を閉じ込める (GETUPVAR / SETUPVAR)、フレームを出た env (unshare)、lambda、
# ブロック引数の自動の splat、入れ子のブロック、&blk
def twice
  yield 1
  yield 2
end

twice { |x| puts x * 10 }
sum = 0
twice { |x| sum += x }
puts sum

def make_counter
  n = 0
  inc = -> { n += 1 }
  get = -> { n }
  [inc, get]
end

c = make_counter
c[0].call
c[0].call
puts c[1].call

def with_block(&b)
  b
end

pr = with_block { |a, b| (a || 0) + (b || 0) }
puts pr.call(1, 2)
puts pr.call([3, 4])
puts pr.call(5)

l = ->(a) { a * 2 }
puts l.call(21)

def nest
  a = 1
  twice { |x| twice { |y| a += x * y } }
  a
end
puts nest

def pass_through(&b)
  twice(&b)
end
pass_through { |x| puts x + 100 }
