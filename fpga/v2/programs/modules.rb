# module (V2b): include、attr_accessor、module_function、特異メソッド、extend、method_missing、respond_to?、send、private
module Greet
  def greet
    "hi " + name
  end
end

class Person
  include Greet
  attr_accessor :name

  def initialize(n)
    @name = n
  end
end

pa = Person.new("Ann")
puts pa.greet
pa.name = "Bob"
puts pa.greet

module Tools
  module_function

  def twice(x)
    x * 2
  end
end
puts Tools.twice(21)

o = Object.new
def o.hello
  "singleton hello"
end
puts o.hello

class Ghost
  def method_missing(name, *args)
    "ghost:" + name.to_s + ":" + args.size.to_s
  end
end
puts Ghost.new.anything(1, 2)
puts 5.respond_to?(:to_s), 5.respond_to?(:nope)
puts 5.send(:+, 3)

module Loud
  def shout
    "LOUD"
  end
end
s = Object.new
s.extend(Loud)
puts s.shout

class Secret
  def pub
    hidden + 1
  end

  private

  def hidden
    41
  end
end
puts Secret.new.pub
puts Secret.new.respond_to?(:hidden)
