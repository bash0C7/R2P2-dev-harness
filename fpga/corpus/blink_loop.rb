# PicoRuby でよく書く形の blink: loop do と times で待つ
led = 0
loop do
  led = 1 - led
  $LED = led
  300.times { }
end
