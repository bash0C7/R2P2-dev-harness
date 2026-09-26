# 定数の path (A::B::X、class A::B、A::X = v)、字句の入れ子 (cref)、一般のグローバル変数
X = 1

module Outer
  X = 10
  K = 3

  class Inner
    V = 4
    def self.v = V + K     # 字句の入れ子で Outer::K
    def x = X              # Outer::X
  end
end

class Outer::Deep
  def d = 5
  def x = X                # class Outer::Deep の cref は Outer::Deep と一番外だけ: 一番外の X
end

module Outer
  module Leaf
    W = Inner::V * 2       # Outer::Inner::V
  end
end

class Outer::Err < Outer::Inner; end   # 空の本体、A::B の親

Outer::Z = 6

$LED = Outer::K                  # 3
$LED = Outer::Inner::V           # 4
$LED = Outer::Inner.v            # 7
$LED = Outer::Inner.new.x        # 10
$LED = Outer::Deep.new.d         # 5
$LED = Outer::Deep.new.x         # 1
$LED = Outer::Leaf::W            # 8
$LED = Outer::Z                  # 6
$LED2 = Outer::Err.new.is_a?(Outer::Inner) # true
$LED2 = $count.nil?              # true (代入前のグローバル変数は nil)
$count ||= 0
3.times { $count += 1 }
$LED = $count                    # 3
def bump = ($count += 10)
bump
$LED = $count                    # 13
