# 戻ったメソッドの変数を捕まえた Proc (env の退避)、lambda の return / break / 引数、proc の中の return (有限)
def make_counter(start)
  count = start
  inc = proc { count += 1 }
  get = proc { count }
  [inc, get]
end

def make_adder(n)
  lambda { |x| x + n }
end

def early(list)
  list.each do |v|
    l = lambda { |y| return y * 10 } # lambda から戻るだけで、early からは戻らない
    l.call(v)
    return v if v > 2                # proc (each のブロック) の return は early から戻る
  end
  0
end

inc, get = make_counter(5)
inc.call
inc.call
$LED = get.call        # 7: 2本の Proc が同じ退避済みの env を共有する

a = make_counter(100)
b = make_counter(200)
a[0].call
$LED = a[1].call       # 101
$LED = b[1].call       # 200

add3 = make_adder(3)
$LED = add3.call(4)    # 7

$LED = early([1, 2, 5, 9]) # 5

stop = lambda { |x| break x * 2 } # lambda の中の break は lambda から戻る
$LED = stop.call(21)   # 42

def nested
  x = 1
  outer = proc do
    inner = lambda { x += 10; return x }
    inner.call + 100   # lambda の return は inner から戻る
  end
  outer.call
end
$LED = nested          # 111
