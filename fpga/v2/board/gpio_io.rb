# GPIO の入出力と、tick に揃わない sleep_ms (板のモデル: docs/superpowers/plans/2026-09-28-fpga-v2-s7-gems.md)
led = GPIO.new(LED_PIN, GPIO::OUT)
button = GPIO.new(3, GPIO::IN | GPIO::PULL_DOWN)
puts "button #{button.read} #{button.low?}"
GPIO.pull_up_at(3)
puts "pulled up #{GPIO.read_at(3)} #{GPIO.high_at?(3)}"
n = 0
loop do
  led.write(n % 2)
  GPIO.write_at(5, 1 - n % 2) if n == 2
  GPIO.set_dir_at(5, GPIO::OUT) if n == 1
  puts "#{n} #{led.read} #{led.high?}"
  sleep_ms(n * 3 + 1)
  n += 1
end
