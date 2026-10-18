require "minitest/autorun"
require_relative "rite_image"

# 起動の像 (rite_core の ROM の先頭) と、回路が読む番号の package が揃っていること
class FpgaRiteImageTest < Minitest::Test
  def test_package_is_generated_from_the_tables
    assert_equal FpgaRiteImage.pkg, File.read(FpgaRiteImage::PKG, encoding: "UTF-8"),
                 "fpga/rtl/rite_image_pkg.sv is stale: run rake fpga:rite:hex"
  end

  def test_image_sections
    b = FpgaRiteImage.image
    assert_equal "RIMG", b[0, 4].pack("C*")
    pos = 4
    assert_equal FpgaRiteImage::PRESYM.size, b[pos]
    pos += 1
    FpgaRiteImage::PRESYM.each do |_, name|
      assert_equal name, b[pos + 1, b[pos]].pack("C*")
      pos += 1 + b[pos]
    end
    [[FpgaRiteImage::CLASSES.size, 6], [FpgaRiteImage::CONSTS.size, 7], [FpgaRiteImage::METHODS.size, 4],
     [FpgaRiteImage::OBJECTS.size, 1]].each do |n, size|
      assert_equal n, b[pos]
      pos += 1 + n * size
    end
    assert_equal b.size, pos
  end

  # 回路の表の大きさ (rite_core.sv の NCLS、NMT、NCONST) と番号の幅に収まる
  def test_tables_fit_the_circuit
    assert_operator FpgaRiteImage::CLASSES.size, :<, 32
    assert_operator FpgaRiteImage::METHODS.size, :<=, 64
    assert_operator FpgaRiteImage::CONSTS.size, :<=, 32
    assert_operator FpgaRiteImage::FUNCS.size, :<=, 16
  end
end
