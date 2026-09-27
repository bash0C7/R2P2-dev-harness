require "minitest/autorun"
require_relative "build"

# firmware (fpga/firmware/*.rb) の決まりを確かめる
class FpgaV2FirmwareTest < Minitest::Test
  L = FpgaV2::Layout

  def value_of(name)
    case name
    when /\AIMG_(\w+)\z/ then L::IMG.fetch(Regexp.last_match(1).to_sym)
    when /\ATT_(\w+)\z/ then L::TT.fetch(Regexp.last_match(1).to_sym)
    else L.const_get(name)
    end
  end

  # 数の横の `# L:名前` は、その行に layout の値の数がある
  def test_layout_annotations_match_layout
    n = 0
    FpgaV2::Build.firmware_sources.each do |f|
      File.readlines(f).each_with_index do |line, i|
        code, comment = line.split("#", 2)
        next unless comment
        comment.scan(/L:(\w+)/).flatten.each do |name|
          v = value_of(name)
          nums = (code + comment).scan(/\b\d+\b/).map(&:to_i)
          assert_includes nums, v, "#{File.basename(f)}:#{i + 1}: L:#{name} = #{v}"
          n += 1
        end
      end
    end
    assert_operator n, :>, 30
  end

  # 探索の外れの罠は、中で命令と __fpga_* だけを使う (自分がまた外れて罠に入らない、設計 §14)
  def test_lookup_trap_calls_only_privileged_primitives
    img = FpgaV2::Image.new(firmware: FpgaV2::Build.firmware)
    img.build
    obj = img.classes.fetch("Object")
    pr = img.mt_get(img.r32(obj + L::C_ROM), img.syms.fetch("__trap_lookup"))
    ir = img.r32(pr + L::P_BODY)
    sends = []
    img.each_insn(ir) do |i|
      sends << img.sym_name(img.irep_sym(ir, i.b)) if i.name.match?(/\AS?SEND/)
      refute_includes %w[GETIDX GETIDX0 SETIDX STRING ARRAY], i.name, "#{i.name} sends or traps"
    end
    refute_empty sends
    sends.each { |s| assert s.start_with?("__fpga_"), "__trap_lookup sends #{s}" }
  end
end
