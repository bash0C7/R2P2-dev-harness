# firmware の estalloc (fpga/firmware/estalloc.rb、mruby ソースコード) を CRuby で走らせる道具 (計画 S6 §6)。
# 同じ file を名前空間の中で読み (`class Object` は名前空間の中の新しいクラスになり、CRuby の Object を変えない)、
# 回路の primitive (__fpga_ld8 / st8 / ld32 / st32 / and / or / xor / shl / shr / copy / image) を binary の String の記憶の上で持つ。
# 使う所: 像の pool を並べる (image.rb、計画 S6-2)、C の .so と比べる (estalloc_test.rb)
require_relative "layout"

module FpgaV2
  class EstHost
    SRC = File.expand_path("../../../fpga/firmware/estalloc.rb", __dir__)
    MASK64 = (1 << 64) - 1

    # 回路の primitive (ref.rb の prim_call と同じ意味)
    module Prims
      def s64(v) = (v &= MASK64) >= 1 << 63 ? v - (1 << 64) : v
      def __fpga_ld8(a) = @mem.getbyte(a)
      def __fpga_st8(a, v) = (@mem.setbyte(a, v & 0xFF); nil)
      def __fpga_ld32(a) = @mem.byteslice(a, 4).unpack1("N")
      def __fpga_st32(a, v) = (@mem[a, 4] = [v & 0xFFFF_FFFF].pack("N"); nil)
      def __fpga_and(a, b) = s64(a & b)
      def __fpga_or(a, b) = s64(a | b)
      def __fpga_xor(a, b) = s64(a ^ b)
      def __fpga_shl(a, b) = s64(a << b)
      def __fpga_shr(a, b) = a >> b
      def __fpga_copy(dst, src, n) = (@mem[dst, n] = @mem.byteslice(src, n); nil)
      def __fpga_image(k) = __fpga_ld32(k * Layout::WORD)
    end

    def self.firmware_class
      @firmware_class ||= begin
        ns = Module.new
        ns.module_eval(File.read(SRC, encoding: "UTF-8"), SRC)
        k = ns.const_get(:Object, false)
        k.include(Prims)
        k
      end
    end

    attr_reader :fw

    # mem: 記憶 (binary の String)。ここで書き換える
    def initialize(mem)
      @fw = self.class.firmware_class.allocate
      @fw.instance_variable_set(:@mem, mem)
    end

    def mem = @fw.instance_variable_get(:@mem)

    # firmware の def を名前で呼ぶ (例: call(:__fpga_est_malloc, pool, 16))
    def call(name, *args) = @fw.__send__(name, *args)
  end
end
