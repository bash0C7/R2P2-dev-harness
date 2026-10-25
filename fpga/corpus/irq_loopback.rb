# 刺激なしの IRQ: 出力にしたピンを自分で上げ下げし、その変化 (EDGE) を IRQ.process で受ける。枠が尽きる、
# 知らない id の解除、PWM の設定と読み戻し、ADC (入力なしは 0) も。CRuby とも比べる
require "irq"

pin = GPIO.new(7, GPIO::OUT)
seen = []
h = pin.irq(GPIO::EDGE_RISE | GPIO::EDGE_FALL) { |g, ev| seen << [g.pin, ev] }
pin.write(1)
pin.write(0)
pin.write(1)
p IRQ.process
p seen
seen.clear
h.disable
pin.write(0)
p IRQ.process
p seen
h.enable
p h.unregister
begin
  h.unregister
rescue => e
  puts e.message
end
ids = []
begin
  17.times { ids << GPIO.new(8, GPIO::IN).irq(GPIO::EDGE_RISE) { } }
rescue RuntimeError => e
  puts "#{ids.size} #{e.message}"
end
pwm = PWM.new(3, frequency: 440)
p pwm.duty(12.5)
p __io_read(0x143)
pwm.frequency(0)
p __io_read(0x143)
p ADC.new(27).read_raw
begin
  ADC.new(5)
rescue ArgumentError => e
  puts e.message
end
