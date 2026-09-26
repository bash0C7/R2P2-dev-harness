# 外のチップの表示器を、コアが I2C / SPI に書いたバイトの列から組み立てる (FPGA の外にあるので回路には無い)。
# エミュレーター (emu.rb) と参照のトレースの両方から使う。docs/spec.md §10「I2C と SPI (P5d)」。
#
# 列の要素: [:i2c_addr, 番地] [:i2c, バイト] [:i2c_stop] [:spi, バイト] [:gpio_out, 32 本の出力の値]
#   SSD1306 (I2C 0x3C): 制御バイト 0x00 の後は命令 (0x21 列の範囲、0x22 ページの範囲 ...)、0x40 の後は画素 (横に進む)
#   AQM0802 (I2C 0x3E、ST7032): 0x00 の後は命令 (0x01 消す、0x02 先頭、0x80 | 番地)、0x40 の後は文字。2行 × 8 文字
#   UC8151 (SPI、DC は GPIO 20): 命令 0x13 (DTM2) の後のデータが新しい画面 (128 × 296、横に 8 画素、1 が白)
module FpgaDisplays
  SSD1306_ADDR = 0x3C
  LCD_ADDR = 0x3E
  UC8151_DC_PIN = 20

  # trace の O 行 (参照かシミュレーション) から列を作る
  def self.from_trace(trace)
    trace.grep(/\AO /).filter_map do |l|
      _, _, port, _, v = l.split
      value = v.to_i(16)
      case port.to_i
      when 0x180 then [:i2c_addr, value & 0x7F]
      when 0x181 then [:i2c, value & 0xFF]
      when 0x183 then [:i2c_stop]
      when 0x190 then [:spi, value & 0xFF]
      when 0x101 then [:gpio_out, value]
      end
    end
  end

  class Ssd1306
    ARGS = { 0x20 => 1, 0x21 => 2, 0x22 => 2, 0x81 => 1, 0x8D => 1, 0xA8 => 1, 0xD3 => 1, 0xD5 => 1, 0xD9 => 1, 0xDA => 1,
             0xDB => 1 }.freeze

    attr_reader :ram, :pages_used

    def initialize
      @ram = Array.new(8) { Array.new(128, 0) }
      @c0 = 0
      @c1 = 127
      @p0 = 0
      @p1 = 7
      @col = 0
      @page = 0
      @pages_used = 0
    end

    def transaction(bytes)
      return if bytes.empty?
      if (bytes[0] & 0x40).zero?
        commands(bytes[1..])
      else
        bytes[1..].each { |b| data(b) }
      end
    end

    def commands(bytes)
      i = 0
      while i < bytes.size
        c = bytes[i]
        args = bytes[i + 1, ARGS[c] || 0]
        case c
        when 0x21
          @c0, @c1 = args.map { |x| x & 0x7F }
          @col = @c0
        when 0x22
          @p0, @p1 = args.map { |x| x & 7 }
          @page = @p0
        end
        i += 1 + (ARGS[c] || 0)
      end
    end

    def data(b)
      @ram[@page][@col] = b
      @pages_used = [@pages_used, @page + 1].max
      @col += 1
      return if @col <= (@c1 || 127)
      @col = @c0 || 0
      @page += 1
      @page = @p0 || 0 if @page > (@p1 || 7)
    end

    def written?
      @pages_used > 0
    end

    # 行ごとの文字列 ('#' が点いた画素)
    def render
      (0...(@pages_used * 8)).map { |y| (0...128).map { |x| (@ram[y / 8][x] >> (y % 8)) & 1 == 1 ? "#" : "." }.join }
    end
  end

  class Lcd
    def initialize
      @ddram = Array.new(0x80, 0x20)
      @addr = 0
      @written = false
    end

    def transaction(bytes)
      i = 0
      while i + 1 < bytes.size
        ctrl = bytes[i]
        v = bytes[i + 1]
        (ctrl & 0x40).zero? ? instruction(v) : char(v)
        i += 2
        break if (ctrl & 0x80).zero? # Co = 0: 残りはすべて同じ種類
      end
      rest = bytes[i..] || []
      return if rest.empty?
      ctrl = bytes[i - 2] || 0
      rest.each { |v| (ctrl & 0x40).zero? ? instruction(v) : char(v) }
    end

    def instruction(v)
      if v == 0x01
        @ddram.fill(0x20)
        @addr = 0
      elsif v == 0x02 || v == 0x03
        @addr = 0
      elsif v & 0x80 != 0
        @addr = v & 0x7F
      end
    end

    def char(v)
      @ddram[@addr] = v
      @addr = (@addr + 1) & 0x7F
      @written = true
    end

    def written?
      @written
    end

    def lines
      [@ddram[0, 8], @ddram[0x40, 8]].map { |l| l.pack("C*") }
    end
  end

  class Uc8151
    DTM2 = 0x13

    attr_reader :frame

    def initialize
      @cmd = nil
      @buf = []
      @frame = nil
    end

    def byte(b, dc)
      if dc.zero?
        @frame = @buf if @cmd == DTM2 && !@buf.empty?
        @cmd = b
        @buf = []
      elsif @cmd == DTM2
        @buf << b
      end
    end

    # 横 296 × 縦 128 (landscape) を 2 × 2 画素ずつ1文字に ('#' が黒)
    def render
      return [] unless @frame
      (0...64).map do |cy|
        (0...148).map do |cx|
          black = [[0, 0], [1, 0], [0, 1], [1, 1]].any? do |dx, dy|
            x = cx * 2 + dx
            y = cy * 2 + dy
            bx = y
            by = 295 - x
            i = by * 16 + bx / 8
            i < @frame.size && ((@frame[i] >> (7 - bx % 8)) & 1).zero?
          end
          black ? "#" : "."
        end.join
      end
    end
  end

  # 列を順に流し、表示器ごとの最後の状態 {ssd1306:, lcd:, uc8151:}
  def self.decode(events)
    oled = Ssd1306.new
    lcd = Lcd.new
    epd = Uc8151.new
    addr = nil
    bytes = []
    gpio = 0
    flush = lambda do
      if addr == SSD1306_ADDR then oled.transaction(bytes)
      elsif addr == LCD_ADDR then lcd.transaction(bytes)
      end
      bytes = []
    end
    events.each do |kind, v|
      case kind
      when :i2c_addr
        flush.call unless bytes.empty?
        addr = v
      when :i2c then bytes << v
      when :i2c_stop then flush.call
      when :gpio_out then gpio = v
      when :spi then epd.byte(v, (gpio >> UC8151_DC_PIN) & 1)
      end
    end
    flush.call unless bytes.empty?
    epd.byte(0, 0) # 最後のデータも画面にする
    { ssd1306: oled, lcd: lcd, uc8151: epd }
  end

  # 人が読む形 (書かれた表示器だけ)
  def self.format(state)
    out = []
    if state[:lcd].written?
      out << "lcd (AQM0802)"
      state[:lcd].lines.each { |l| out << "  |#{l}|" }
    end
    if state[:ssd1306].written?
      out << "ssd1306"
      state[:ssd1306].render.each { |l| out << "  #{l}" }
    end
    if state[:uc8151].frame
      out << "uc8151 (2 x 2 pixels per character)"
      state[:uc8151].render.each { |l| out << "  #{l}" }
    end
    out
  end
end
