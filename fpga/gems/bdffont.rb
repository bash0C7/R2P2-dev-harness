# FPGA 版の bdffont gem。PicoRuby の picoruby-bdffont (mrblib/bdffont.rb) と同じ API。フォントの gem (terminus、
# karmatic_arcade、shinonome) は無いので、setup は何も include しない (PicoRuby でフォントの gem を入れていない時と同じく、
# draw_text は NoMethodError)
module BDFFont
  def self.setup(klass)
    nil
  end

  module Drawable
    def bdffont_draw_result(result, x, y)
      height = result[0]
      widths = result[2]
      glyphs = result[3]
      glyph_x = x
      i = 0
      while i < widths.size
        draw_bitmap(x: glyph_x, y: y, w: widths[i], h: height, data: glyphs[i])
        glyph_x += widths[i]
        i += 1
      end
      nil
    end

    def draw_text(fontname, x, y, text, scale = 1)
      font = fontname.to_s.split("_")[0]
      case font
      when "terminus"
        puts "Terminus font is not available"
      when "shinonome"
        puts "Shinonome font is not available"
      when "karmatic-arcade"
        puts "Karmatic Arcade font is not available"
      else
        raise "Unsupported font: #{font}"
      end
    end
  end
end
