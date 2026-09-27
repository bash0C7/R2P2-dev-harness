require "minitest/autorun"
require_relative "parallel"

class FpgaParallelTest < Minitest::Test
  %i[map threads].each do |how|
    # 終わる順がばらばらでも items の順で返す
    define_method("test_#{how}_keeps_order") do
      items = (0...12).to_a
      out = FpgaParallel.public_send(how, items, jobs: 4) do |i|
        sleep(0.002 * ((12 - i) % 5))
        i * i
      end
      assert_equal items.map { |i| i * i }, out
    end

    # 仕事の例外は親で FpgaParallel::Error になり、何番の何かが message に出る
    define_method("test_#{how}_raises_in_parent") do
      e = assert_raises(FpgaParallel::Error) do
        FpgaParallel.public_send(how, [1, 2, 3], jobs: 3) { |i| i == 2 ? raise(ArgumentError, "bad 2") : i }
      end
      assert_match(/item 1: ArgumentError: bad 2/, e.message)
    end

    define_method("test_#{how}_empty") do
      assert_equal [], FpgaParallel.public_send(how, [], jobs: 4) { |i| i }
    end

    # jobs 1 はその場で順に回す (同じ process、同じ thread)
    define_method("test_#{how}_one_job_runs_inline") do
      seen = []
      out = FpgaParallel.public_send(how, [1, 2, 3], jobs: 1) do |i|
        seen << [Process.pid, Thread.current]
        i + 1
      end
      assert_equal [2, 3, 4], out
      assert_equal [[Process.pid, Thread.current]], seen.uniq
    end
  end

  # map は別の process で回す (CRuby の CPU を使う仕事が並ぶ)。結果は Marshal で戻る
  def test_map_runs_in_children
    pids = FpgaParallel.map([1, 2, 3, 4], jobs: 2) { |_| Process.pid }
    refute_includes pids, Process.pid
    assert_equal [[1, "a"], { k: 2.5 }], FpgaParallel.map([1, 2], jobs: 2) { |i| i == 1 ? [1, "a"] : { k: 2.5 } }
  end

  def test_jobs_from_env
    old = ENV["FPGA_JOBS"]
    ENV["FPGA_JOBS"] = "3"
    assert_equal 3, FpgaParallel.jobs
    ENV["FPGA_JOBS"] = ""
    assert_operator FpgaParallel.jobs, :>=, 1
  ensure
    ENV["FPGA_JOBS"] = old
  end
end
