# FPGA 版の vram gem。PicoRuby の picoruby-vram (src/vram.c と src/mruby/vram.c) を Ruby で。画面を cols × rows のページに分け、
# ページごとに String の中身を持つ。縦 (SSD1306: 1バイト = 縦 8 画素、下位 bit が上) と横 (UC8151: 1バイト = 横 8 画素、
# 上位 bit が左) の並び、反転、回転 (0 / 90 / 180 / 270) も C と同じ。
class VRAM
  attr_accessor :name

  class Page
    def initialize(x, y, w, h, horizontal, invert, rotate)
      @x = x
      @y = y
      @w = w
      @h = h
      @horizontal = horizontal
      @invert = invert
      @rotate = rotate
      @buf_w = rotate == 90 || rotate == 270 ? h : w
      @buf_h = rotate == 90 || rotate == 270 ? w : h
      size = horizontal ? ((@buf_w + 7) / 8) * @buf_h : @buf_w * ((@buf_h + 7) / 8)
      @buffer = "\0" * size
      @dirty = false
      fill(0)
    end

    attr_reader :x, :y, :w, :h, :buffer
    attr_accessor :dirty

    def contains?(x, y)
      x >= @x && x < @x + @w && y >= @y && y < @y + @h
    end

    # ページの中の座標 (回転の前) の画素
    def set(lx, ly, color)
      case @rotate
      when 90
        bx = ly
        by = @w - 1 - lx
      when 180
        bx = @w - 1 - lx
        by = @h - 1 - ly
      when 270
        bx = @h - 1 - ly
        by = lx
      else
        bx = lx
        by = ly
      end
      return if bx < 0 || bx >= @buf_w || by < 0 || by >= @buf_h
      color = color == 0 ? 1 : 0 if @invert
      if @horizontal
        i = (bx / 8) + by * ((@buf_w + 7) / 8)
        bit = 7 - (bx % 8)
      else
        i = bx + (by / 8) * @buf_w
        bit = by % 8
      end
      return if i >= @buffer.bytesize
      b = @buffer.getbyte(i)
      @buffer.setbyte(i, color != 0 ? b | (1 << bit) : b & ~(1 << bit) & 0xFF)
      @dirty = true
    end

    def fill(color)
      color = color == 0 ? 1 : 0 if @invert
      v = color != 0 ? 0xFF : 0x00
      i = 0
      n = @buffer.bytesize
      while i < n
        @buffer.setbyte(i, v)
        i += 1
      end
      @dirty = true
    end
  end

  def initialize(w:, h:, cols:, rows:, layout: :vertical, invert: false, rotate: 0)
    @w = w
    @h = h
    page_w = w / cols
    page_h = h / rows
    @pages = []
    ty = 0
    while ty < rows
      tx = 0
      while tx < cols
        @pages << Page.new(tx * page_w, ty * page_h, page_w, page_h, layout == :horizontal, invert ? true : false,
                           rotate.is_a?(Integer) ? rotate : 0)
        tx += 1
      end
      ty += 1
    end
  end

  # [[col, row, data], ...]。clear_dirty なら dirty の印を消す
  def __vram_pages(dirty_only, clear_dirty)
    result = []
    i = 0
    while i < @pages.size
      page = @pages[i]
      if !dirty_only || page.dirty
        cols = @w / page.w
        result << [i % cols, i / cols, page.buffer]
        page.dirty = false if clear_dirty
      end
      i += 1
    end
    result
  end

  def pages(clear_dirty = true)
    __vram_pages(false, clear_dirty)
  end

  def dirty_pages(clear_dirty = true)
    __vram_pages(true, clear_dirty)
  end

  def set_pixel(x, y, color)
    i = 0
    while i < @pages.size
      page = @pages[i]
      if page.contains?(x, y)
        page.set(x - page.x, y - page.y, color)
        break
      end
      i += 1
    end
    self
  end

  # Bresenham (C と同じ順に点を打つ)
  def draw_line(x0, y0, x1, y1, color)
    dx = x1 > x0 ? x1 - x0 : x0 - x1
    dy = y1 > y0 ? y1 - y0 : y0 - y1
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx - dy
    x = x0
    y = y0
    while true
      set_pixel(x, y, color)
      break if x == x1 && y == y1
      e2 = 2 * err
      if e2 > -dy
        err -= dy
        x += sx
      end
      if e2 < dx
        err += dx
        y += sy
      end
    end
    self
  end

  def draw_rect(x, y, w, h, color)
    i = 0
    while i < h
      j = 0
      while j < w
        set_pixel(x + j, y + i, color)
        j += 1
      end
      i += 1
    end
    self
  end

  def fill(color)
    @pages.each { |page| page.fill(color) }
    self
  end

  def erase(x, y, w, h)
    draw_rect(x, y, w, h, 0)
  end

  # data: 行ごとの Integer (上位 bit が左)
  def draw_bitmap(x:, y:, w:, h:, data:)
    raise ArgumentError, "Invalid arguments for draw_bitmap" unless data.is_a?(Array)
    return self if w <= 0 || h <= 0
    iy = 0
    while iy < h && iy < data.size
      row = data[iy]
      if row.is_a?(Integer)
        ix = 0
        while ix < w
          set_pixel(x + ix, y + iy, (row >> (w - 1 - ix)) & 1)
          ix += 1
        end
      end
      iy += 1
    end
    self
  end

  # data: 行ごとに (w + 7) / 8 バイト (上位 bit が左)
  def draw_bytes(x:, y:, w:, h:, data:)
    raise ArgumentError, "Invalid arguments for draw_bytes" unless data.is_a?(String)
    return self if w <= 0 || h <= 0
    stride = (w + 7) / 8
    n = data.bytesize
    iy = 0
    while iy < h
      ix = 0
      while ix < w
        i = iy * stride + ix / 8
        pixel = i < n ? (data.getbyte(i) >> (7 - ix % 8)) & 1 : 0
        set_pixel(x + ix, y + iy, pixel)
        ix += 1
      end
      iy += 1
    end
    self
  end
end

class VRAM
  module Delegatable
    def set_pixel(x, y, color = 1)
      return if x < 0 || x >= @width || y < 0 || y >= @height
      @vram.set_pixel(x, y, color)
    end

    def draw_bitmap(x:, y:, w:, h:, data:)
      @vram.draw_bitmap(x: x, y: y, w: w, h: h, data: data)
      nil
    end

    def draw_bytes(x:, y:, w:, h:, data:)
      @vram.draw_bytes(x: x, y: y, w: w, h: h, data: data)
      nil
    end

    def draw_line(x0, y0, x1, y1, color = 1)
      @vram.draw_line(x0, y0, x1, y1, color)
      nil
    end

    def draw_rect(x, y, w, h, color = 1, fill = false)
      if fill
        @vram.draw_rect(x, y, w, h, color)
      else
        draw_line(x,         y,         x + w - 1, y,         color)
        draw_line(x,         y + h - 1, x + w - 1, y + h - 1, color)
        draw_line(x,         y,         x,         y + h - 1, color)
        draw_line(x + w - 1, y,         x + w - 1, y + h - 1, color)
      end
      nil
    end
  end
end
