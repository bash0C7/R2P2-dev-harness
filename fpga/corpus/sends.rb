# 動的な呼び出し (P7): send / __send__ / public_send (Symbol と String の名前)、&:sym (Symbol#to_proc)、String#to_sym
class Greeter
  def initialize(name)
    @name = name
  end

  def hello(greeting = "hello", mark = "!")
    "#{greeting}, #{@name}#{mark}"
  end

  def each_twice
    yield 1
    yield 2
  end
end

g = Greeter.new("fpga")
puts g.send(:hello)
puts g.send(:hello, "hi")
puts g.__send__(:hello, "yo", "?")
puts g.public_send(:hello)
p 3.send(:+, 4)
p [1, 2, 3].send(:size)
g.send(:each_twice) { |x| p x * 10 }
p [1, 2, 3].map(&:to_s)
p %w[a bb ccc].map(&:size)
p [[1, 2], [3, 4]].map(&:first)
p [1, 2, 3, 4].select(&:even?)
p [3, 1, 2].sort.map(&:succ)
begin
  g.send(:nosuch)
rescue NoMethodError => e
  puts e.class
end
begin
  puts g.send("hello", "hey")
  g.send("nosuch2")
rescue NoMethodError => e
  puts e.class
end
begin
  g.send(1)
rescue TypeError => e
  puts "TypeError #{e.message}"
end
p "size".to_sym
