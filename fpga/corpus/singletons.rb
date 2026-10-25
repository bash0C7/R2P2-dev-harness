# クラスのインスタンス変数 (本体と特異メソッドの @x はクラスごと)、class << self、::X (一番外の定数)
module Registry
  @items = {}
  @count = 0

  class << self
    def add(name, value)
      @items[name] = value
      @count += 1
      self
    end

    def count
      @count
    end

    def [](name)
      @items[name]
    end
  end

  def self.names
    @items.keys
  end
end

class Counter
  @total = nil

  def self.total
    @total
  end

  def self.bump(n)
    @total = (@total || 0) + n
  end
end

class Nested
  LIMIT = 3

  def self.limit
    ::Nested::LIMIT + ::Registry.count
  end
end

Registry.add(:a, 1).add(:b, 2)
p Registry.count
p Registry[:b]
p Registry.names
p Counter.total
Counter.bump(5)
Counter.bump(7)
p Counter.total
p Nested.limit
