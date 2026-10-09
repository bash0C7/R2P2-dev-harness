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

  # 写し元の注釈 (計画 S2-4): firmware の全 def と layout.rb の全定数に `# C:`、写し元の名前がその file にある
  def test_every_def_and_layout_field_names_its_c_source
    require_relative "annotations"
    assert_equal [], FpgaV2::Annotations.check
    assert_equal [], FpgaV2::Annotations.check_layout
  end

  # SEND 先 (計画 S2-4): firmware の def が送るのは、写し元の C の関数が動的に呼ぶもの (棚卸しの dyn) と __fpga_ だけ
  def test_sends_only_what_the_c_source_dispatches
    require_relative "annotations"
    assert_equal [], FpgaV2::Annotations.check_sends
  end

  # 計画 S6 §3.4 / §3.5: firmware は Proc を作らない (firmware のフレームは irep の番地で判る)、GC の本体は確保しない
  def test_no_proc_making_and_no_allocation_inside_the_gc
    require_relative "annotations"
    assert_equal [], FpgaV2::Annotations.check_alloc_ops
  end

  # 計画 S6 §3.5: GC の関所の表 (C の関数が辿って使う GC の API を firmware も使うか) は、commit したものが今の firmware と C から作ったものと同じ
  def test_gc_calls_table_is_current
    require_relative "annotations"
    assert_equal File.read(FpgaV2::Annotations::GC_CALLS), FpgaV2::Annotations.gc_calls_tsv, "rake fpga:v2:inventory で作り直す"
  end

  # 引数の数 (計画 S5): C のメソッドの写しの def は C の aspec と同じ範囲を受ける (mruby は呼ぶ前に調べる)
  def test_defs_take_the_c_aspec
    require_relative "annotations"
    assert_equal [], FpgaV2::Annotations.check_aspec
  end

  # 参照 v2 の命令は、名前がそのまま vm.c の CASE (OP_<名前>) で、命令の表 (ops.tsv) にある
  def test_ref_opcodes_are_vm_c_cases
    ops = File.readlines(File.join(FpgaV2::Build::ROOT, "fpga", "v2", "inventory", "ops.tsv"), chomp: true)
              .reject { |l| l.start_with?("#") }.map { |l| l.split("\t").first }
    handled = File.read(File.join(__dir__, "ref.rb")).scan(/when ((?:"[A-Z0-9_]+"(?:, )?)+)/).flatten
                  .flat_map { |w| w.scan(/"([A-Z0-9_]+)"/).flatten }.uniq
    refute_empty handled
    assert_equal [], handled - ops
  end

  # 探索の外れの罠は、中で命令と __fpga_* だけを使う (自分がまた外れて罠に入らない、設計 §14)
  def test_lookup_trap_calls_only_privileged_primitives
    img = FpgaV2::Image.new(firmware: FpgaV2::Build.firmware)
    img.build
    obj = img.classes.fetch("Object")
    pr = img.mt_get(img.r32(obj + L::C_ROM), img.syms.fetch("__fpga_trap_lookup"))
    ir = img.r32(pr + L::P_BODY)
    sends = []
    img.each_insn(ir) do |i|
      sends << img.sym_name(img.irep_sym(ir, i.b)) if i.name.match?(/\AS?SEND/)
      refute_includes %w[GETIDX GETIDX0 SETIDX STRING ARRAY], i.name, "#{i.name} sends or traps"
    end
    refute_empty sends
    sends.each { |s| assert_includes FpgaV2::Image::PRIMS, s, "__fpga_trap_lookup sends #{s}" } # 回路の primitive だけ (firmware の helper も __fpga_ で始まる)
  end
end
