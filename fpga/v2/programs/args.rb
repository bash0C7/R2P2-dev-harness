# 引数 (ENTER): 必須・省略可能・残り・後ろの必須と、実行時の def の再定義 (後の def は実行した時から効く)
def opt(a, b = 10, c = 20)
  a + b + c
end
puts opt(1), opt(1, 2), opt(1, 2, 3)

def rest(a, *r)
  puts a, r.size
end
rest(1)
rest(1, 2, 3)

def post(a, *r, z)
  puts a, r.size, z
end
post(1, 2)
post(1, 2, 3, 4)

def f
  1
end
puts f
def f
  2
end
puts f
x = 7
if x > 5
  def g
    "big"
  end
else
  def g
    "small"
  end
end
puts g
