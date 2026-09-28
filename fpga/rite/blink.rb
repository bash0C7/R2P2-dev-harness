# Lチカ (計画 §2.1) の while 版。rite_core (mruby のバイトコードを直接実行する回路の最初の反復) が走らせる
led = GPIO.new(28, GPIO::OUT)
while true
  led.write(1)
  sleep_ms 500
  led.write(0)
  sleep_ms 500
end
