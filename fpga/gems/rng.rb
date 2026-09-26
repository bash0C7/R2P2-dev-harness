# FPGA 版の rng gem。RNG.random_int はデバイスの xorshift32 (tools/fpga/devices.rb の RNG) の次の値。
# 同じ ROM なら毎回同じ列 (シミュレーションで参照と一致させるため)。
module RNG
  def self.random_int
    __io_read(0x130) & 0x7FFF_FFFF
  end

  def self.uuid
    hex = ""
    i = 0
    while i < 32
      hex << (RNG.random_int % 16).to_s(16)
      i += 1
    end
    [hex[0, 8], hex[8, 4], "4" + hex[13, 3], %w[8 9 a b][RNG.random_int % 4] + hex[17, 3], hex[20, 12]].join("-")
  end
end

class Object
  def rand(max = 0)
    max == 0 ? RNG.random_int : RNG.random_int % max
  end
end
