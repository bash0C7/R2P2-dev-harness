# オブジェクト: new / initialize、インスタンス変数、attr_*、継承と super、module の include、is_a? / respond_to?、
# クラス変数、一番外のインスタンス変数 (有限)
module Scaled
  def scaled(k)
    @scale = k
    value * @scale
  end
end

class Counter
  attr_reader :count
  attr_accessor :step
  @@made = 0

  def initialize(start, step)
    @count = start
    @step = step
    @@made += 1
  end

  def tick
    @count += @step
    self
  end

  def value
    @count
  end

  def self.made
    @@made
  end
end

class Doubler < Counter
  include Scaled

  def initialize(start)
    super(start, 2)
    @extra = 100
  end

  def tick
    super
    @count += 1
    self
  end

  def value
    super + @extra
  end
end

c = Counter.new(10, 3)
c.tick.tick
$LED = c.count             # 16
c.step = 5
c.tick
$LED = c.value             # 21
d = Doubler.new(1)
d.tick
$LED = d.count             # 4
$LED = d.value             # 104
$LED = d.scaled(2)         # 208
$LED = Counter.made        # 2
$LED2 = d.is_a?(Counter)   # true
$LED2 = d.is_a?(Scaled)    # true
$LED2 = c.is_a?(Doubler)   # false
$LED2 = d.kind_of?(Object) # true
$LED2 = Counter === d      # true
$LED2 = Integer === d      # false
$LED2 = d.instance_of?(Counter) # false
$LED2 = d.respond_to?(:scaled)  # true
$LED2 = c.respond_to?(:scaled)  # false
$LED2 = d.class == Doubler # true
$LED2 = nil.nil?           # true
$LED2 = c.nil?             # false
@top = 7
$LED = @top + 1            # 8
