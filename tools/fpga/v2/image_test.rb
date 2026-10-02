require "minitest/autorun"
require_relative "build"

# 起動の像の道具 (image.rb) が作る irep と、firmware の loader (fpga/firmware/boot.rb の __fpga_load、mruby の load.c) が
# 実行時に同じ .mrb から作る irep が同じか (firmware は build の時の表、プログラムは実行時に読む。両方が同じ形であること)
class FpgaV2ImageTest < Minitest::Test
  L = FpgaV2::Layout

  def setup
    skip "host の mrbc が無い (rake fpga:picoruby)" unless File.executable?(FpgaV2::Build.mrbc)
  end

  # firmware の __fpga_load が返した irep を、__fpga_run の所で取り出す
  class Capture < FpgaV2::Ref
    attr_reader :loaded

    def run_irep(pr, _self, _a)
      @loaded = r32(pr + L::P_BODY) # __fpga_run は firmware が作った Proc を受ける (load.c の mrb_proc_new)
      raise Halt
    end
  end

  def tree(get, ir, sym_name)
    f = %i[I_ILEN I_ISEQ I_PLEN I_SLEN I_RLEN I_CATCH I_CLEN].to_h { |k| [k, get.(:r32, ir + L.const_get(k))] }
    f[:nlocals_nregs] = get.(:r32, ir + L::I_NLOCALS)
    f[:pool] = (0...f[:I_PLEN]).map { |k| get.(:rv, get.(:r32, ir + L::I_POOL) + k * L::VALUE) }
    f[:syms] = (0...f[:I_SLEN]).map do |k|
      id = get.(:r32, get.(:r32, ir + L::I_SYMS) + k * 4)
      id == L::NULL_SYM ? nil : sym_name.(id)
    end
    f[:reps] = (0...f[:I_RLEN]).map { |k| tree(get, get.(:r32, get.(:r32, ir + L::I_REPS) + k * 4), sym_name) }
    f
  end

  def test_firmware_loader_builds_the_same_ireps_as_the_image_tool
    files = Dir[File.join(FpgaV2::Build::ROOT, "fpga/v2/programs/*.rb")].sort.first(2) +
            Dir[File.join(FpgaV2::Build::ROOT, "fpga/corpus/{floats,strings,classes}.mrb")]
    fw = FpgaV2::Build.firmware
    files.each do |f|
      bin = f.end_with?(".mrb") ? File.binread(f) : FpgaV2::Build.compile([f])
      img = FpgaV2::Image.new(firmware: fw, programs: [bin])
      mem = img.build
      blob = img.r32(img.r32(L::IMG[:programs] * 4))
      ref = Capture.new(mem)
      ref.run
      # 道具の irep は同じ像の上にもう1つ作る (.mrb のバイト列は同じ番地を指す)
      tool_ir = img.irep_top(blob)
      tool = tree(->(m, a) { m == :rv ? tool_rv(img, a) : img.r32(a) }, tool_ir, ->(id) { img.sym_name(id) })
      fwt = tree(->(m, a) { ref.send(m, a) }, ref.loaded, ->(id) { ref.sym_name(id) })
      assert_equal tool, fwt, File.basename(f)
    end
  end

  def tool_rv(img, a)
    tag = img.r32(a)
    v = (img.r32(a + 8) << 32) | img.r32(a + 12)
    v -= 1 << 64 if tag == L::TAG_INT && v >= 1 << 63
    [tag, v]
  end

  # 起動の像: firmware の class の本体の def が ROM の表に入り、コアのクラスの親は mruby と同じ
  def test_core_classes_and_rom_tables
    img = FpgaV2::Image.new(firmware: FpgaV2::Build.firmware)
    img.build
    c = img.classes
    sup = ->(name) { img.r32(c.fetch(name) + L::C_SUPER) }
    assert_equal c["Numeric"], img.r32(sup.("Integer") + 0).then { sup.("Integer") }
    assert_equal c["BasicObject"], img.r32(sup.("Object") + L::C_SUPER) # Object → Kernel の iclass → BasicObject
    assert img.mt_get(img.r32(c["Integer"] + L::C_ROM), img.syms.fetch("to_s"))
    assert img.mt_get(img.r32(c["Kernel"] + L::C_ROM), img.syms.fetch("puts"))
  end
end
