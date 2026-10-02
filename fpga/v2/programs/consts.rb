# 定数 (V2b): 字句の外側、親クラス、入れ子の module、トップレベル (mruby の mrb_vm_const_get: cref → 祖先 → Object)
module Config
  LIMIT = 10
  class Box
    def limit
      LIMIT
    end
  end
end

class Base
  SIZE = 3
end

class Sub < Base
  def size
    SIZE
  end
end

puts Config::Box.new.limit
puts Sub.new.size
puts Config::LIMIT
X = 5
def top_x
  X
end
puts top_x
class Sub
  SIZE = 4
end
puts Sub.new.size
