# 16 段階のソフト PWM。duty を 0..15 と上げ、各周期で $LED を duty の間だけ点ける
duty = 0
while true
  t = 0
  while t < 16
    if t < duty
      $LED = 1
    else
      $LED = 0
    end
    t += 1
  end
  duty += 1
  duty = 0 if duty > 15
end
