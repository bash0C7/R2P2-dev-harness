# クラス (V2b): initialize と new、インスタンス変数と attr_reader、継承と super、クラスの再オープン (定義は実行した時から効く)
class Animal
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def speak
    "..."
  end

  def to_s
    name + " says " + speak
  end
end

class Dog < Animal
  def speak
    "Woof"
  end
end

class Puppy < Dog
  def speak
    super + "!"
  end
end

puts Dog.new("Rex")
puts Puppy.new("Bit")
a = Animal.new("x")
puts a.name
puts a.speak
class Animal
  def speak
    "(silence)"
  end
end
puts a.speak
puts Puppy.new("Q").speak
