require "minitest/autorun"
require_relative "displays"

class FpgaDisplaysTest < Minitest::Test
  def i2c(addr, *bytes)
    [[:i2c_addr, addr], *bytes.map { |b| [:i2c, b] }, [:i2c_stop]]
  end

  def test_ssd1306_follows_the_column_and_page_window
    ev = i2c(0x3C, 0x00, 0x21, 1, 2, 0x22, 0, 1) + i2c(0x3C, 0x40, 0x01, 0x80, 0x03, 0xFF)
    rows = FpgaDisplays.decode(ev)[:ssd1306].render
    assert_equal 16, rows.size
    assert_equal ".#..", rows[0][0, 4]  # 列 1 (0x01) の下位 bit がページ 0 の y = 0
    assert_equal "..#.", rows[7][0, 4]  # 0x80 は y = 7
    assert_equal ".##.", rows[8][0, 4]  # ページ 1 へ折り返す
  end

  def test_lcd_writes_two_lines
    ev = [0x38, 0x0c, 0x01].flat_map { |c| i2c(0x3E, 0x00, c) } + "Hi".bytes.flat_map { |c| i2c(0x3E, 0x40, c) } +
         i2c(0x3E, 0x00, 0xC0) + i2c(0x3E, 0x40, 0x21)
    lcd = FpgaDisplays.decode(ev)[:lcd]
    assert lcd.written?
    assert_equal ["Hi      ", "!       "], lcd.lines
  end

  def test_uc8151_takes_the_frame_after_dtm2
    dc = 1 << FpgaDisplays::UC8151_DC_PIN
    ev = [[:gpio_out, 0], [:spi, 0x13], [:gpio_out, dc]] + Array.new(4736) { |i| [:spi, i.zero? ? 0x7F : 0xFF] } +
         [[:gpio_out, 0], [:spi, 0x12]]
    epd = FpgaDisplays.decode(ev)[:uc8151]
    assert_equal 4736, epd.frame.size
    rows = epd.render
    assert_equal 64, rows.size
    # バッファの (bx 0, by 0) = 横長の (x 295, y 0) が黒 -> 右上の文字
    assert_equal "#", rows[0][147]
    assert_equal ".", rows[0][0]
  end

  def test_from_trace_reads_bus_writes
    trace = ["X 1 1 2f", "O 1 384 3 0000003c", "O 2 385 3 00000040", "O 3 387 3 00000000", "O 4 400 3 00000013",
             "O 5 257 3 00100000"]
    assert_equal [[:i2c_addr, 0x3C], [:i2c, 0x40], [:i2c_stop], [:spi, 0x13], [:gpio_out, 0x100000]],
                 FpgaDisplays.from_trace(trace)
  end
end
