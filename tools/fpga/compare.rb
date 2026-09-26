# 参照インタプリタ (ref_vm.rb) とシミュレーション (fpga/sim/mrb_run_tb.sv) のトレースの突き合わせ。
#
# 合否は I/O の系列 (O 行) と終わり方 (最後の H/E/L 行) で決める。
# 食い違ったら、トレース全体 (X/W/O) で最初にずれた行を探し、その step の命令を示す。
require_relative "isa"

module FpgaCompare
  Result = Struct.new(:ok, :io_count, :ending, :message, keyword_init: true)

  module_function

  def io_lines(trace)
    trace.grep(/\A[OHEL] /)
  end

  def compare(ref, sim, words: nil)
    ref = ref.map(&:strip).reject(&:empty?)
    sim = sim.map(&:strip).reject(&:empty?)
    ref_io = io_lines(ref)
    sim_io = io_lines(sim)
    if ref_io == sim_io
      return Result.new(ok: true, io_count: ref_io.count { |l| l.start_with?("O ") }, ending: ref_io.last, message: nil)
    end

    Result.new(ok: false, io_count: nil, ending: sim_io.last, message: divergence(ref, sim, words))
  end

  def divergence(ref, sim, words)
    idx = (0...[ref.size, sim.size].max).find { |i| ref[i] != sim[i] }
    return "traces differ only in I/O ordering" unless idx

    step = (ref[idx] || sim[idx]).split[1].to_i
    x = ref.find { |l| l.start_with?("X #{step} ") }
    where = if x
              pc = x.split[2].to_i
              op = FpgaIsa::OPS[x.split[3].to_i(16)]&.name || x.split[3]
              "step #{step}, pc #{pc} (#{op})"
            else
              "step #{step}"
            end
    lines = ["first difference at #{where}:",
             "  reference: #{ref[idx] || '(end of trace)'}",
             "  simulation: #{sim[idx] || '(end of trace)'}"]
    lines.join("\n")
  end

  # O 行を人が読む形に。[port 名, 値] の列。
  def outputs(trace)
    trace.grep(/\AO /).map do |l|
      _, _, port, tag, val = l.split
      [port.to_i, decode(tag.to_i, val.to_i(16))]
    end
  end

  def decode(tag, val)
    case tag
    when FpgaIsa::TAG_NIL   then nil
    when FpgaIsa::TAG_FALSE then false
    when FpgaIsa::TAG_TRUE  then true
    else val >= 2**31 ? val - 2**32 : val
    end
  end

  def read_stim(path)
    return [] unless path && File.file?(path)
    File.readlines(path, chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.map do |l|
      l.split.map(&:to_i)
    end
  end
end
