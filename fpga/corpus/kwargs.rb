# キーワード引数: 必須 / 省略可能、**opts、**h で渡す、new と initialize、ブロック、kd でないメソッドへの Hash
def area(w:, h: 2)
  w * h
end

def opts(a, k: 1, **rest)
  a + k + rest.size * 100
end

def only_rest(**o)
  o
end

def plain(x, y = nil)
  y.nil? ? x : x + y.size
end

class Box
  attr_reader :w, :h
  def initialize(w:, h: 1)
    @w = w
    @h = h
  end
end

def with_block(k: 1)
  yield k
end

$LED = area(w: 3)                  # 6
$LED = area(h: 5, w: 3)            # 15
$LED = opts(1)                     # 2
$LED = opts(1, k: 5)               # 6
$LED = opts(1, k: 5, z: 9, q: 0)   # 206
kw = { w: 4, h: 4 }
$LED = area(**kw)                  # 16
none = {}
$LED = opts(7, **none)             # 8
p only_rest, only_rest(a: 1, b: 2)
$LED = plain(1, z: 3)              # 2 (kd でないメソッドには Hash が最後の引数)
b = Box.new(w: 2, h: 7)
$LED = b.w * b.h                   # 14
$LED = Box.new(w: 9).h             # 1
$LED = with_block(k: 4) { |v| v * 10 } # 40
l = ->(x, k: 2) { x * k }
$LED = l.call(3)                   # 6
$LED = l.call(3, k: 5)             # 15
