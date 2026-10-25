# コアの実行時エラーとプレリュードのエラーを rescue する: 0 で割る、メソッドが無い、引数の数、型、KeyError、Integer()。
# メッセージは PicoRuby の形なので、CRuby と同じになるものだけ出す。無いメソッドは __ で始める (fpga:gap は数えない)
def try
  yield
rescue => e
  puts e.class
  e
end

e = try { 10 / 0 }
puts e.message
try { 7 % 0 }
try { nil.upcase }
try { 3.__no_such_method(1) }
try { [1, 2].__frobnicate }

def two(a, b)
  a + b
end
e = try { two(1) }
puts e.message
e = try { two(1, 2, 3) }
puts e.message
try { [1].first(1, 2, 3) }

try { 1 + nil }
try { 5 - "x" }
e = try { 3 < nil }
try { 1 << :a }

e = try { { a: 1 }.fetch(:b) }
e = try { Integer("12x") }
puts e.message
p Integer("0x1f") + Integer(" -42 ") + Integer("1_000")

def kw(a:, b: 2)
  a + b
end
e = try { kw(b: 1) }
puts e.message
e = try { kw(a: 1, c: 3) }
puts e.message

# 捕まえた後も続けられる、ensure も走る
total = 0
[4, 0, 2].each do |d|
  begin
    total += 8 / d
  rescue ZeroDivisionError
    total += 100
  ensure
    total += 1
  end
end
p total

class Meter
  def initialize(limit)
    @limit = limit
  end

  def read(x)
    raise ArgumentError, "too big" if x > @limit
    x * 2
  end
end
m = Meter.new(5)
p [1, 9, 3].map { |x| m.read(x) rescue -1 }
