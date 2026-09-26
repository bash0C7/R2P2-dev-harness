# FPGA の CPU コアで、プログラムの前に置いて一緒に変換する組み込みメソッド (mruby の mrblib と同じ役目)。
# 回路は primitive (tools/fpga/isa.rb の PRIMS) とメソッド探索だけを持ち、それを組み合わせるメソッドはここに Ruby で書く。
# CRuby / picoruby でも同じ意味になる書き方だけを使う (参照の突き合わせで CRuby に同じ file を読ませる)。

class Integer
  def times
    i = 0
    while i < self
      yield i
      i += 1
    end
    self
  end

  def upto(last)
    i = self
    while i <= last
      yield i
      i += 1
    end
    self
  end

  def downto(last)
    i = self
    while i >= last
      yield i
      i -= 1
    end
    self
  end
end

class Array
  def each
    i = 0
    while i < size
      yield self[i]
      i += 1
    end
    self
  end

  def each_with_index
    i = 0
    while i < size
      yield self[i], i
      i += 1
    end
    self
  end

  def map
    result = []
    i = 0
    while i < size
      result << yield(self[i])
      i += 1
    end
    result
  end
end

class Object
  def loop
    while true
      yield
    end
  end

  def proc(&block)
    block
  end
end

class Object
  def !=(other)
    !(self == other)
  end
end

class Array
  def ==(other)
    return false unless other.class == Array
    return false unless size == other.size
    i = 0
    while i < size
      return false unless self[i] == other[i]
      i += 1
    end
    true
  end

  def include?(value)
    each { |x| return true if x == value }
    false
  end
end

class Object
  def initialize
  end

  def nil?
    false
  end

  def instance_of?(klass)
    self.class == klass
  end
end

class NilClass
  def nil?
    true
  end
end

class Module
  def ===(object)
    object.is_a?(self)
  end
end
