# クラスとモジュール (インスタンスを作らない範囲): クラスメソッド、継承、組み込みクラスへの追加、
# モジュール関数、メソッドの上書き、演算子の落ち先 (配列の ==)、class (有限)
class Calc
  def self.add(a, b)
    a + b
  end

  def self.twice(x)
    add(x, x)
  end
end

class Calc2 < Calc
  def self.twice(x)
    add(x, x) + 1 # 親のクラスメソッドを self で呼ぶ
  end
end

class Integer
  def double
    self * 2
  end

  def clamp_to(lo, hi)
    return lo if self < lo
    return hi if self > hi
    self
  end
end

module Util
  def self.sum(list)
    s = 0
    list.each { |v| s += v }
    s
  end
end

def helper(x)
  x.double + 1
end

$LED = Calc.add(2, 3)        # 5
$LED = Calc2.twice(4)        # 9
$LED = Calc.twice(4)         # 8
$LED = 21.double             # 42
$LED = 20.clamp_to(0, 10)    # 10
$LED = Util.sum([1, 2, 3, 4]) # 10
$LED = helper(3)             # 7
$LED2 = [1, [2, 3]] == [1, [2, 3]] # true
$LED2 = [1, 2] == [1, 3]     # false
$LED2 = [1, 2] != [1, 2]     # false
$LED2 = [1, 2].include?(2)   # true
$LED2 = 3.class == Integer   # true
$LED2 = Calc.class == Class  # true
$LED2 = :a == :a             # true
3.times { |i| $LED = helper(i) } # 1, 3, 5
