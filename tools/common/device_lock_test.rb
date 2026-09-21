require "minitest/autorun"
require "tmpdir"
require_relative "device_lock"

class DeviceLockTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @env = {}
    @out = StringIO.new
    @t = 0.0
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def acquire(target = "rp2040", pid: 100, alive: ->(_) { true }, wait: 5, env: @env)
    DeviceLock.acquire(target, wait: wait, root: @root, pid: pid, env: env, alive_fn: alive,
                       sleep_fn: ->(s) { @t += s }, now_fn: -> { Time.at(@t) }, out: @out)
  end

  def test_acquire_then_release_frees_the_board
    assert acquire
    assert_equal "100", @env[DeviceLock.env_key("rp2040")]
    DeviceLock.release("rp2040", root: @root, pid: 100, env: @env)
    refute File.exist?(File.join(@root, "rp2040.lock"))
    assert acquire(pid: 200, env: {})
  end

  def test_second_process_waits_then_times_out_naming_the_holder
    acquire(pid: 100)
    err = assert_raises(DeviceLock::Timeout) { acquire(pid: 200, env: {}, wait: 2) }
    assert_includes err.message, "pid 100"
    assert_includes @out.string, "held by pid 100"
  end

  def test_child_of_the_holder_passes_without_owning
    acquire(pid: 100)
    assert_equal false, acquire(pid: 200, env: @env) # env carries holder 100
    DeviceLock.release("rp2040", root: @root, pid: 200, env: @env) # not the owner: no-op
    assert File.exist?(File.join(@root, "rp2040.lock"))
  end

  def test_dead_holder_is_taken_over
    acquire(pid: 100)
    assert acquire(pid: 200, env: {}, alive: ->(pid) { pid != 100 })
    assert_equal "200", File.read(File.join(@root, "rp2040.lock", "owner")).split.first
  end

  def test_different_boards_do_not_block_each_other
    acquire("rp2040", pid: 100)
    assert acquire("esp32", pid: 200, env: {})
  end

  def test_synchronize_releases_even_when_the_block_raises
    assert_raises(RuntimeError) do
      DeviceLock.synchronize("esp32", root: @root, pid: 100, env: @env, out: @out) { raise "boom" }
    end
    refute File.exist?(File.join(@root, "esp32.lock"))
  end

  def test_synchronize_holds_during_the_block
    DeviceLock.synchronize("esp32", root: @root, pid: 100, env: @env, out: @out) do
      assert_raises(DeviceLock::Timeout) { acquire("esp32", pid: 200, env: {}, wait: 1) }
    end
  end

  def test_release_by_non_owner_keeps_the_lock
    acquire(pid: 100)
    DeviceLock.release("rp2040", root: @root, pid: 999, env: {})
    assert File.exist?(File.join(@root, "rp2040.lock"))
  end
end
