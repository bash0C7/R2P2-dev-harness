# Lチカ (計画 §2.1) の loop 版。rite_core (mruby のバイトコードを直接実行する回路) が、ROM の先頭の mrblib (kernel.rb の Kernel#loop) と一緒に走らせる
led = GPIO.new(28, GPIO::OUT)
loop do
  led.write(1)
  sleep_ms 500
  led.write(0)
  sleep_ms 500
end
