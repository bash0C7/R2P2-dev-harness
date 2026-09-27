# firmware: Enumerable の C の所 (mruby の src/enum.c)。Enumerable#hash (mrblib/enum.rb) が要素の hash を混ぜる
module Enumerable
  # hash ^= ((uint32_t)hv << (index % 16))。左に寄せた値も 32bit で切る (C の uint32_t の桁)
  # C: src/enum.c enum_update_hash
  def __update_hash(hash, index, hv)
    hash = __fpga_as_int(hash) # mrb_get_args の iii
    index = __fpga_as_int(index)
    hv = __fpga_as_int(hv)
    __fpga_xor(hash, __fpga_and(__fpga_shl(__fpga_and(hv, 4294967295), __fpga_rem(index, 16)), 4294967295))
  end

  # C: src/enum.c enum_update_hash
  def self.__update_hash(hash, index, hv)
    hash = __fpga_as_int(hash) # mrb_get_args の iii
    index = __fpga_as_int(index)
    hv = __fpga_as_int(hv)
    __fpga_xor(hash, __fpga_and(__fpga_shl(__fpga_and(hv, 4294967295), __fpga_rem(index, 16)), 4294967295))
  end
end
