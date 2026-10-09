# デバイス: GPIO (出力、入力の pull up / pull down、open drain)、UART の送信、RNG、Machine。
# gem は FPGA 版 (fpga/gems/)。require しなくても定数を使えば入る (R2P2 と同じ)
require "uart"

led = GPIO.new(16, GPIO::OUT)
button = GPIO.new(17, GPIO::IN | GPIO::PULL_UP)
sensor = GPIO.new(18, GPIO::IN | GPIO::PULL_DOWN)
bus = GPIO.new(19, GPIO::OUT | GPIO::OPEN_DRAIN)

3.times do |i|
  led.write(i % 2)
  puts "led #{led.read} button #{button.read} high? #{button.high?} sensor low? #{sensor.low?}"
end

bus.write(0)
p bus.read
bus.write(1)
p bus.read # 離すと pull が無いので 0
p [led.pin, GPIO.read_at(17), GPIO.low_at?(18)]

begin
  GPIO.new(40, GPIO::OUT)
rescue ArgumentError => e
  puts e.message
end
begin
  GPIO.new(3, GPIO::IN | GPIO::OUT)
rescue ArgumentError => e
  puts e.message
end

uart = UART.new(unit: :RP2040_UART0, txd_pin: 0, rxd_pin: 1, baudrate: 115_200)
p uart.write("hello\r\n")
uart.puts "line"
uart.putc 65
p uart.baudrate
p uart.read
p uart.gets
p uart.bytes_available

r = [RNG.random_int, RNG.random_int, rand(10), rand(10)]
p r
p RNG.uuid.size

t = Machine.uptime_us
Machine.delay_ms(5)
p Machine.uptime_us - t >= 5000 || Machine.uptime_us == 0
p Machine.mcu_name
