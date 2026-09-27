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
      yield __aget(i)
      i += 1
    end
    self
  end

  def each_with_index
    i = 0
    while i < size
      yield __aget(i), i
      i += 1
    end
    self
  end

  def map
    result = []
    i = 0
    while i < size
      result << yield(__aget(i))
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

  # 動的な呼び出し (P7)。回路の __send (名前の Symbol を外して残りの引数で呼ぶ) に引数の数で分けて渡す
  # (splat で渡すと引数が配列1つになり、primitive の受け手の検査が通らないため)。名前は Symbol か String
  # (String はプログラムのシンボル表から探し、無ければどのメソッドの名前でもないので NoMethodError)
  def send(name, *args, &blk)
    if name.is_a?(String)
      s = name.__find_sym
      raise NoMethodError, "undefined method '#{name}' for #{self.class}" unless s
      name = s
    end
    raise TypeError, "#{name.inspect} is not a symbol nor a string" unless name.is_a?(Symbol)
    case args.size
    when 0 then __send(name, &blk)
    when 1 then __send(name, args[0], &blk)
    when 2 then __send(name, args[0], args[1], &blk)
    when 3 then __send(name, args[0], args[1], args[2], &blk)
    when 4 then __send(name, args[0], args[1], args[2], args[3], &blk)
    when 5 then __send(name, args[0], args[1], args[2], args[3], args[4], &blk)
    when 6 then __send(name, args[0], args[1], args[2], args[3], args[4], args[5], &blk)
    else raise ArgumentError, "send passes up to 6 arguments on the FPGA core"
    end
  end

  # defined?(X) の値 (X がクラスかモジュールの時。変換器が __defined_const? をこれにする)
  def __const_str
    "constant"
  end

  # 即値だけ (ヒープのオブジェクトはコピー GC で動くので決まった数を持てない)
  def object_id
    id = __object_id
    raise NotImplementedError, "object_id of a heap object is not available on the FPGA core" if id.nil?
    id
  end

  def __send__(name, *args, &blk)
    send(name, *args, &blk)
  end

  def public_send(name, *args, &blk)
    send(name, *args, &blk)
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
      return false unless __aget(i) == other.__aget(i)
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

class Object
  # require は変換の前に解いてある (tools/fpga/corpus.rb の gem_files)。実行時は何もしない
  def require(name)
    true
  end
end

# GC はヒープが足りなくなった時にコアが動かす (コピー GC)。start は何もしない (いつ動いても結果は同じ)
module GC
  def self.start
    nil
  end
end

class Proc
  # Proc.new { } はブロックの Proc そのもの
  def self.new(&block)
    raise ArgumentError, "tried to create Proc object without a block" unless block
    block
  end
end
