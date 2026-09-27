# 正しさの基準 (oracle): プログラムを host の PicoRuby (tools の VM、build_config/fpga-tools.rb、R2P2 と同じ MRB_INT64) で走らせた出力。
# FPGA のコアの出力は、参照 (ref_vm.rb) と一致するだけでなく、これと同じでなければならない (docs/superpowers/plans/2026-09-27-fpga-v2.md)。
#
# 走らせ方は gap と同じ: gem の test は upstream の rake test の Runner と同じ頭 (require 'picotest' と gem の require の名前) と
# 末尾 (test_* を1つずつ呼んで JSON)、picotest のテストのファイルは末尾だけ。止まらないプログラム (blink の loop など) は
# TIMEOUT 秒で切り、それまでの出力を取る (:timeout)。host では stdout を pipe にすると C の stdio が溜めるので、pty ではなく
# stdbuf で行ごとに出させる
require "json"
require "open3"
require "fileutils"
require_relative "gap"

module FpgaOracle
  TIMEOUT = 10
  Result = Struct.new(:path, :status, :out, :err, :seconds, keyword_init: true)

  module_function

  def default_picoruby = FpgaConverter.default_picoruby

  # host で走らせる mruby ソースコード (gap と同じ頭と末尾)。範囲外なら nil
  def script(path)
    src = File.read(path, encoding: "UTF-8").scrub
    head = FpgaGap.gem_test_head(path)
    src = head + src if head
    return nil if FpgaGap.out_of_scope(src)
    tail = FpgaGap.picotest_tail(src)
    (tail && !head ? "require 'picotest'\n" : "") + src + tail.to_s
  end

  # 1本を host で走らせる。dir に写しを書く (相対の require_relative は範囲外なので path を変えてよい)
  def run(path, dir:, picoruby: default_picoruby, timeout: TIMEOUT)
    s = script(path)
    return Result.new(path: path, status: :out_of_scope, out: "", err: "", seconds: 0) unless s
    copy = File.join(dir, FpgaGap.rel(path).tr("/", "_"))
    File.write(copy, s)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, st = Open3.capture3("timeout", "-s", "KILL", timeout.to_s, "stdbuf", "-o0", "-e0", picoruby, copy, stdin_data: "")
    sec = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    status = if st.termsig == 9 || st.exitstatus == 137 then :timeout
             elsif st.success? then :exit
             else :error
             end
    Result.new(path: path, status: status, out: out.force_encoding("UTF-8").scrub, err: err.force_encoding("UTF-8").scrub, seconds: sec.round(2))
  end

  # host の出力と FPGA の出力 (コンソールのバイト列) を比べる。どちらかが途中で切られた (host の :timeout、FPGA の命令数の上限)
  # なら、短い方が長い方の頭と同じなら :prefix。両方が終わっていれば同じ時だけ :same
  def judge(host, fpga_out, fpga_cut:)
    return :same if host.out == fpga_out && host.status != :timeout && !fpga_cut
    cut = host.status == :timeout || fpga_cut
    short, long = [host.out, fpga_out].sort_by(&:bytesize)
    return :prefix if cut && long.start_with?(short)
    :differs
  end
end
