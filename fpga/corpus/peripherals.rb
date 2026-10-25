# P5c のデバイス: GPIO の割り込み (IRQ.process で受ける)、PWM、ADC、console の入力 (STDIN.getch)。
# 刺激は peripherals.stim (262 = 0x106 は外から L にするピン、336 = 0x150 は ADC の入力 0、340 = 0x154 は温度、
# 289 = 0x121 は UART の受信バイト)
require "irq"
require "io/console"

button = GPIO.new(5, GPIO::IN | GPIO::PULL_UP)
led = GPIO.new(16, GPIO::OUT)
pwm = PWM.new(15, frequency: 1000, duty: 25)
p pwm.duty(150)
p pwm.period_us(2000)
p pwm.pulse_width_us(500)
adc = ADC.new(26)
temp = ADC.new("temperature")
presses = 0
events = []
handler = button.irq(GPIO::EDGE_FALL | GPIO::EDGE_RISE, debounce: 0) do |btn, event|
  events << event
  presses += 1 if event == GPIO::EDGE_FALL
  led.write(btn.low? ? 1 : 0)
end
while presses < 2
  IRQ.process
  sleep_ms 1
end
p events
puts "adc #{adc.read_raw} #{format('%.3f', adc.read)} #{temp.read_raw}"
c = STDIN.getch
puts "key #{c}"
p handler.unregister
p IRQ.process
begin
  IRQ.start
rescue NotImplementedError => e
  puts e.class
end
pwm.frequency(0)
