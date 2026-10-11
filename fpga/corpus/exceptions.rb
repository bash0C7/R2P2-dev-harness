# 例外: raise / rescue (クラスで選ぶ、=> e、else) / ensure / retry、メソッドをまたいで捕まえる、
# 例外のクラスを作る、ensure を通り抜ける return / break / next / while の break
class AppError < StandardError
  def initialize(msg = "app failed")
    super
  end
end

class DetailError < AppError
  attr_reader :code

  def initialize(code)
    @code = code
    super("detail #{code}")
  end
end

def check(x)
  raise ArgumentError, "negative" if x < 0
  raise TypeError if x == 0
  x * 2
end

[3, -1, 0].each do |v|
  begin
    puts check(v)
  rescue ArgumentError => e
    puts "arg: #{e.message}"
  rescue => e
    p e
  else
    puts "no error"
  ensure
    puts "done #{v}"
  end
end

def deep(n)
  n == 0 ? raise(DetailError.new(42)) : deep(n - 1)
end

begin
  deep(3)
rescue AppError => e
  p e
  p e.code
  p e.is_a?(StandardError)
  p e.class
end

begin
  raise AppError
rescue StandardError => e
  puts e.message
end

tries = 0
begin
  tries += 1
  raise "try #{tries}" if tries < 3
  puts "ok after #{tries}"
rescue
  retry
end

def with_ensure(log)
  begin
    return :early
  ensure
    log << "ensure ran"
  end
end
log = []
p with_ensure(log)
p log

found = [1, 2, 3, 4].each do |i|
  begin
    break i * 10 if i == 3
  ensure
    log << i
  end
end
p found
p log

i = 0
while true
  begin
    i += 1
    break if i == 4
    next if i == 2
  ensure
    log << "w#{i}"
  end
end
p log

def nested
  begin
    begin
      raise IndexError, "inner"
    ensure
      puts "inner ensure"
    end
  rescue KeyError
    puts "not here"
  end
rescue IndexError => e
  puts "outer: #{e.message}"
  :handled
end
p nested

r = [1, 2].map do |x|
  begin
    raise "odd" if x.odd?
    x
  rescue
    -x
  end
end
p r

x = (raise "inline" rescue "rescued inline")
p x
p $!

def reraise
  yield
rescue => e
  puts "saw #{e.message}"
  raise
end

begin
  reraise { raise RangeError, "again" }
rescue RangeError => e
  p e
end

e = RuntimeError.new("made")
p e
p e.message
p ArgumentError.new.message
