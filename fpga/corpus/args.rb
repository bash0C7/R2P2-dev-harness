# 引数: 省略可能・残り・後ろの必須・&blk、splat の呼び出し、配列の展開 ([*a, x])、a, *b, c = ...、
# ブロックの引数の展開 (|a, b| に配列1つ)、lambda の数の検査、引数なしの super
def opt(a, b = 10, c = b + 1)
  a * 100 + b * 10 + c
end

def rest(a, *r)
  a + r.size * 10
end

def post(a, *m, z)
  a * 100 + m.size * 10 + z
end

def around(a, b = 5, *r, c, &blk)
  blk.call(a + b + r.size + c)
end

def sum(*xs)
  t = 0
  xs.each { |x| t += x }
  t
end

class Base
  def calc(a, b = 2, *r)
    a * 10 + b + r.size * 100
  end
end

class Child < Base
  def calc(a, b = 3, *r)
    super + 1000
  end
end

$LED = opt(1)              # 1 10 11 -> 211
$LED = opt(1, 2)           # 1 2 3 -> 123
$LED = opt(1, 2, 5)        # 125
$LED = rest(1)             # 1
$LED = rest(1, 2, 3)       # 21
$LED = post(1, 2)          # 102
$LED = post(1, 7, 8, 9)    # 129
$LED = around(1, 2) { |v| v * 2 }       # 1 + 5 + 0 + 2 -> 16
$LED = around(1, 2, 3, 4, 5) { |v| v }  # 1 + 2 + 2 + 5 -> 10
xs = [1, 2, 3]
$LED = sum(*xs)            # 6
$LED = sum(0, *xs, 9)      # 15
$LED = opt(*[4, 5])        # 456
ys = [*xs, 4]
$LED = ys.size             # 4
zs = [*xs, *ys, *nil, 7]
$LED = zs.size             # 8
$LED = zs[7]               # 7
p1, *p2, p3 = zs
$LED = p1 + p3             # 8
$LED = p2.size             # 6
q1, *q2, q3 = 5
$LED = q1                  # 5
$LED2 = q3.nil?            # true
$LED = q2.size             # 0
t = 0
[[1, 2], [3, 4]].each { |a, b| t += a * b }
$LED = t                   # 14
u = 0
[[1, 2, 3]].each { |a, *b| u = a + b.size }
$LED = u                   # 3
v = 0
[[10, 20]].each_with_index { |(a, b), i| v = a + b + i }
$LED = v                   # 30
pr = proc { |a, b| (b || 0) + a }
$LED = pr.call(1)          # 1
$LED = pr.call(1, 2, 3)    # 3
$LED = pr.call([4, 5])     # 9
la = ->(a, b = 1) { a + b }
$LED = la.call(2)          # 3
$LED = la.call(2, 3)       # 5
$LED = Child.new.calc(1)       # 1013
$LED = Child.new.calc(1, 4, 7) # 1114
