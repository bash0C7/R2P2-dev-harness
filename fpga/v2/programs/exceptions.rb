# 例外 (計画 S4-2): raise / rescue / ensure / retry、例外のクラスと message、break / return / next の巻き戻し
class AppError < StandardError
end

class CodeError < AppError
  def initialize(code)
    @code = code
    super("code " + code.to_s)
  end

  def code
    @code
  end
end

def risky(n)
  raise ArgumentError, "bad " + n.to_s if n == 1
  raise CodeError.new(n) if n == 2
  raise "plain" if n == 3
  n * 10
end

n = 0
while n < 4
  begin
    puts risky(n)
  rescue CodeError => e
    puts "code: " + e.message + " " + e.code.to_s + " " + e.class.to_s
  rescue ArgumentError, TypeError => e
    puts "arg: " + e.message
  rescue => e
    puts "other: " + e.inspect
  ensure
    puts "ensure " + n.to_s
  end
  n += 1
end

# 呼ばれた先で上がり、呼んだ側で捕まる。途中のフレームの ensure も走る
def inner
  begin
    raise AppError, "deep"
  ensure
    puts "inner ensure"
  end
end

def middle
  inner
  puts "not reached"
end

begin
  middle
rescue AppError => e
  puts "caught " + e.message
end

# retry
tries = 0
begin
  tries += 1
  raise "again" if tries < 3
  puts "tries " + tries.to_s
rescue
  retry
end

# 例外の値と else
def classify(x)
  begin
    100 / x
  rescue ZeroDivisionError => e
    e.message
  else
    "ok"
  end
end
puts classify(0)
puts classify(5)

# 回路と firmware が上げる例外
begin
  9223372036854775807 + 0 + 1
rescue RangeError => e
  puts e.message
end

def two(a, b)
  a + b
end
begin
  two(1)
rescue ArgumentError => e
  puts e.message
end

begin
  nosuch_method_here
rescue NoMethodError => e
  puts e.message
end

# ensure の中の return と、ensure を越える return
def ret_ensure
  begin
    return 1
  ensure
    puts "ret ensure"
  end
end
puts ret_ensure

# ブロックからの break と return (ブロックの外の ensure も走る)
def each_n(n)
  i = 0
  while i < n
    yield i
    i += 1
  end
  :done
end

r = each_n(10) do |i|
  break i * 100 if i == 3
end
puts r

def find_first
  each_n(10) do |i|
    return i if i * i > 20
  end
  nil
end
puts find_first

def with_ensure
  each_n(5) do |i|
    begin
      break i if i == 2
    ensure
      puts "blk ensure " + i.to_s
    end
  end
end
puts with_ensure

# while の中の ensure を break が越える (JMPUW)
k = 0
while true
  begin
    k += 1
    break if k == 3
  ensure
    puts "loop ensure " + k.to_s
  end
end
puts k

# next はブロックから値を返す
s = 0
each_n(5) do |i|
  next if i == 2
  s += i
end
puts s

# 上げ直し
begin
  begin
    raise TypeError, "inner"
  rescue => e
    raise
  end
rescue TypeError => e2
  puts "reraised " + e2.message
end

puts RuntimeError.new("x").inspect
puts StandardError.new.message
