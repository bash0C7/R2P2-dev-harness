require "minitest/autorun"
require_relative "ops"
require_relative "../isa"
require_relative "../rite"

class FpgaV2OpsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  OPS_H = File.join(ROOT, "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby/ops.h")
  OPCODE_H = File.join(ROOT, "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include/mruby/opcode.h")
  D = FpgaV2::Ops

  # 表は vendor の ops.h と同じ (名前・形式・並び)
  def test_table_matches_ops_h
    skip "vendor/picoruby が無い" unless File.exist?(OPS_H)
    assert_equal File.read(OPS_H).scan(/^OPCODE\((\w+),\s*(\w+)\)/), D::TABLE
  end

  def bytes(*a) = a.pack("C*")

  # EXT の組み合わせは opcode.h の FETCH_<形式>_<n> と同じ (a / b / c の幅)
  def test_ext_widths_follow_opcode_h
    skip "vendor/picoruby が無い" unless File.exist?(OPCODE_H)
    h = File.read(OPCODE_H)
    width = { "READ_B" => 1, "READ_S" => 2, "READ_W" => 3 }
    base = h.scan(/#define FETCH_(\w+)\(\) (.*)$/).to_h
    %w[B BB BBB BS BSS S W].each do |fmt|
      (0..3).each do |n|
        body = n.zero? ? base[fmt] : base["#{fmt}_#{n}"]
        body = base[body[/FETCH_(\w+)\(\)/, 1]] while body =~ /\AFETCH_/ # FETCH_B_3() FETCH_B() のような別名
        expect = body.scan(/(\w)=(READ_\w)/).to_h { |k, r| [k, width[r]] }
        op = D::NUM[D::TABLE.find { |_, f| f == fmt }[0]]
        raw = [op] + [0x12] * 8
        raw = [D::NUM["EXT#{n}"]] + raw unless n.zero?
        insn = D.decode(bytes(*raw), 0)
        got = { "a" => insn.a, "b" => insn.b, "c" => insn.c }.compact.transform_values { |v| v > 0xFFFF ? 3 : (v > 0xFF ? 2 : 1) }
        assert_equal expect, got, "#{fmt} EXT#{n}"
        assert_equal raw.size - 8 + expect.values.sum, insn.next_pc, "#{fmt} EXT#{n} length"
      end
    end
  end

  # corpus の全 .mrb の命令列を、v1 の読み取り器 (rite.rb) と同じ区切りと operand に読む
  def test_decodes_every_corpus_iseq_like_rite
    files = Dir[File.join(ROOT, "fpga/corpus/*.mrb")]
    skip "corpus が無い" if files.empty?
    n = 0
    files.each do |f|
      stack = [Rite.parse(File.binread(f))]
      until stack.empty?
        ir = stack.shift
        stack.concat(ir.reps)
        Rite.decode(ir.iseq).each do |ref|
          got = D.decode(ir.iseq, ref.addr)
          assert_equal [ref.name, ref.operands, ref.next_addr], [got.name, [got.a, got.b, got.c].compact, got.next_pc],
                       "#{File.basename(f)} pc #{ref.addr}"
          n += 1
        end
      end
    end
    assert_operator n, :>, 10_000
  end
end
