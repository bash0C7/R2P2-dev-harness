# メソッド定義と呼び出し: 引数、再帰、途中の return、引数なし、nil を返すもの (有限)
def add(a, b)
  a + b
end

def fib(n)
  if n < 2
    n
  else
    fib(n - 1) + fib(n - 2)
  end
end

def sign(x)
  return -1 if x < 0
  return 0 if x == 0
  1
end

def seven
  7
end

def nothing
end

$LED = add(40, 2)
$LED = fib(10)
$LED = sign(-5)
$LED = sign(0)
$LED = sign(9)
$LED = seven + add(seven, 1)
$LED = nothing
$LED2 = fib(1)
