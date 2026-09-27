require_relative "test_helper"
require_relative "oracle"

class FpgaOracleTest < Minitest::Test
  H = FpgaOracle::Result

  # 両方が終わっていれば同じ時だけ same。途中で切られた方が他方の頭なら prefix
  def test_judge
    done = H.new(status: :exit, out: "a\nb\n")
    assert_equal :same, FpgaOracle.judge(done, "a\nb\n", fpga_cut: false)
    assert_equal :differs, FpgaOracle.judge(done, "a\nc\n", fpga_cut: false)
    assert_equal :prefix, FpgaOracle.judge(done, "a\n", fpga_cut: true)
    assert_equal :differs, FpgaOracle.judge(done, "a\n", fpga_cut: false)
    assert_equal :prefix, FpgaOracle.judge(H.new(status: :timeout, out: "a\n"), "a\nb\n", fpga_cut: false)
    assert_equal :differs, FpgaOracle.judge(H.new(status: :timeout, out: "x\n"), "a\nb\n", fpga_cut: true)
  end

  # gem の test は Runner と同じ頭と末尾で走らせる
  def test_script_of_a_gem_test_has_the_runner_head_and_tail
    path = File.join(FpgaGap::ROOT, "vendor/picoruby/mrbgems/picoruby-adc/test/adc_test.rb")
    skip "vendor/picoruby が無い" unless File.exist?(path)
    s = FpgaOracle.script(path)
    assert s.start_with?("require 'picotest'\nrequire 'adc'\n")
    assert_match(/puts JSON\.generate\(my_test\.result\)/, s)
  end

  def test_runs_on_host_picoruby
    skip "host の picoruby が無い (rake fpga:picoruby)" unless File.executable?(FpgaOracle.default_picoruby)
    Dir.mktmpdir do |dir|
      prog = File.join(dir, "p.rb")
      File.write(prog, "puts 1 + 2\n")
      r = FpgaOracle.run(prog, dir: dir)
      assert_equal [:exit, "3\n"], [r.status, r.out]
      File.write(prog, "puts 1\nloop { }\n")
      r = FpgaOracle.run(prog, dir: dir, timeout: 1)
      assert_equal [:timeout, "1\n"], [r.status, r.out] # 切る前の出力も取れる (stdbuf)
    end
  end
end
