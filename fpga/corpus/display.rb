# 表示器: SSD1306 (I2C 0x3C、PicoRuby の ssd1306 gem をそのまま) と AQM0802 の LCD (I2C 0x3E) に書く。VRAM の画素と
# 汚れたページも。刺激なし (既定で 0x3C と 0x3E が応答する) なので CRuby とも比べる
require "ssd1306"

i2c = I2C.new(unit: :RP2040_I2C0, sda_pin: 8, scl_pin: 9, frequency: 400_000)
display = SSD1306.new(i2c: i2c, w: 128, h: 32)
display.draw_rect(2, 2, 20, 10, 1, false)
display.draw_line(0, 31, 127, 0)
display.set_pixel(64, 16, 1)
display.update_display
begin
  display.draw_text("terminus_6x12", 0, 0, "hi") # フォントの gem が無いので PicoRuby でも無い
rescue NoMethodError => e
  puts e.class
end

vram = VRAM.new(w: 16, h: 16, cols: 2, rows: 2)
vram.draw_rect(0, 0, 3, 3, 1)
vram.set_pixel(15, 15, 1)
p vram.dirty_pages.map { |c, r, d| [c, r, d.bytes.sum] }
p vram.dirty_pages.size
h = VRAM.new(w: 16, h: 2, cols: 1, rows: 1, layout: :horizontal, invert: true)
h.set_pixel(0, 0, 1)
h.draw_line(8, 1, 15, 1, 1)
p h.pages[0][2].bytes

# AQM0802 (lcd.rb と同じ命令)
[0x38, 0x39, 0x14, 0x70, 0x56, 0x6c].each { |c| i2c.write(0x3e, 0, c) }
[0x38, 0x0c, 0x01].each { |c| i2c.write(0x3e, 0, c) }
"Hello,".bytes.each { |c| i2c.write(0x3e, 0x40, c) }
i2c.write(0x3e, 0, 0x80 | 0x40)
"World!".bytes.each { |c| i2c.write(0x3e, 0x40, c) }
puts "done"
