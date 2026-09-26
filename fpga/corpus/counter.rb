# 0..9 を数え、1回おきに $LED2 を点ける。数え終わったら $LED に回数を出して止まる (有限)
n = 0
lit = false
while n < 10
  lit = lit ? false : true
  $LED2 = lit ? 1 : 0
  n += 1
end
$LED = n
