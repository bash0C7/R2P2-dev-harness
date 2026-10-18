# sleep_ms で待つ blink (PicoRuby の書き方)。ボードエミュレーターでは実時間で 0.1 秒ごとに反転する
led = 0
loop do
  led = 1 - led
  $LED = led
  sleep_ms 100
end
