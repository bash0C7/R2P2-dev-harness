# P5d の刺激で動くもの: rotary encoder (GPIO 20 / 21 の IRQ)、I2C の読み出し (0x50 に返事)、SPI の温度センサー (ADT7310 風)、
# HC-SR04 (GPIO 1 で trig、GPIO 0 の echo の幅)、Time.now の差。刺激は buses.stim
require "rotary_encoder"
require "hcsr04"

enc = RotaryEncoder.new(20, 21)
turns = []
enc.cw { turns << :cw }
enc.ccw { turns << :ccw }
n = 0
while turns.size < 2 && n < 2000
  IRQ.process
  sleep_ms 1
  n += 1
end
p turns

i2c = I2C.new(unit: :RP2040_I2C0, sda_pin: 4, scl_pin: 5)
p i2c.read(0x50, 3, 0x00).bytes
begin
  i2c.read(0x51, 1)
rescue IOError => e
  puts e.message
end

spi = SPI.new(unit: :RP2040_SPI0, cs_pin: 17, sck_pin: 18, cipo_pin: 16, copi_pin: 19)
spi.select do
  data = spi.read(2).bytes
  temp = (data[0] << 8 | data[1]) >> 3
  puts "temp #{temp / 16.0}"
end
p spi.transfer(0x01, 0x02, additional_read_bytes: 1).bytes

t0 = Time.now
hc = HCSR04.new(trig: 1, echo: 0)
puts "distance #{hc.distance_cm} cm"
dt = Time.now - t0
puts dt > 0 && dt < 1
