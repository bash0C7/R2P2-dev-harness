# USB::Peripheral のライフサイクル。USB にも実機にも触らない範囲だけを見る。
#
# fake は method の中で Class.new する。picotest の runner は test file を
# まず CRuby で load して test class を数えるので、top level で USB の定数に
# 触るとその時点で NameError になる (target VM でしか USB は居ない)。
class USBPeripheralTest < Picotest::Test

  def test_run_requires_a_tick_block
    assert_raise(USB::Peripheral::Error) { build_device.run }
  end

  def test_connected_is_not_implemented_by_the_base_class
    assert_raise(USB::Peripheral::NotImplementedByPort) { USB::Peripheral.new.connected? }
  end

  def test_waits_for_the_host_before_setup
    dev = build_device(connect_delay: 3, ticks_per_session: 1)
    dev.setup { |d| d.log << :setup }
    dev.tick { |d| d.log << :tick }
    dev.run
    assert_equal [:setup, :tick, :restore], dev.log
    assert_equal 3, dev.waits
  end

  def test_tick_runs_while_connected_and_stops_on_disconnect
    dev = build_device(ticks_per_session: 3)
    dev.tick { |d| d.log << :tick }
    dev.run
    assert_equal [:tick, :tick, :tick, :restore], dev.log
  end

  def test_stop_from_inside_tick_breaks_the_loop
    dev = build_device(ticks_per_session: 5)
    dev.tick { |d| d.log << :tick; d.stop }
    dev.run
    assert_equal [:tick, :restore], dev.log
    assert_equal true, dev.stopped?
  end

  def test_teardown_runs_after_the_host_state_is_restored
    dev = build_device(ticks_per_session: 1)
    dev.tick { |d| d.log << :tick }
    dev.teardown { |d| d.log << :teardown }
    dev.run
    assert_equal [:tick, :restore, :teardown], dev.log
  end

  def test_host_state_is_restored_even_when_tick_raises
    dev = build_device(ticks_per_session: 1)
    dev.tick { |_d| raise ArgumentError, "boom" }
    dev.teardown { |d| d.log << :teardown }
    assert_raise(ArgumentError) { dev.run }
    assert_equal [:restore, :teardown], dev.log
  end

  def test_a_disconnect_sends_it_back_to_waiting_for_the_host
    dev = build_device(ticks_per_session: 1, sessions: 2, reconnect: true)
    dev.setup { |d| d.log << :setup }
    dev.tick do |d|
      d.log << :tick
      d.stop if 2 <= d.session_count
    end
    dev.run
    assert_equal [:setup, :tick, :restore, :setup, :tick, :restore], dev.log
  end

  def test_reconnect_false_leaves_after_one_session
    dev = build_device(ticks_per_session: 1, sessions: 2, reconnect: false)
    dev.tick { |d| d.log << :tick }
    dev.run
    assert_equal [:tick, :restore], dev.log
    assert_equal 1, dev.session_count
  end

  def test_idle_is_skipped_when_the_interval_is_zero
    dev = build_device(ticks_per_session: 5, idle_ms: 0)
    dev.tick { |d| d.stop }
    dev.run
    assert_equal [], dev.idles
  end

  def test_idle_uses_the_configured_intervals
    dev = build_device(ticks_per_session: 5, connect_delay: 1,
                       idle_ms: 7, connect_poll_ms: 3)
    dev.tick { |d| d.stop }
    dev.run
    # 接続待ちの 1 回 (3ms) と、tick のあとの 1 回 (7ms)
    assert_equal [3, 7], dev.idles
  end

  def test_pump_is_driven_while_waiting_and_while_ticking
    dev = build_device(ticks_per_session: 2, connect_delay: 2)
    dev.tick { |d| d.log << :tick }
    dev.run
    assert_equal 4, dev.pumps
  end

  private def build_device(connect_delay: 0, ticks_per_session: 1, sessions: 1,
                           idle_ms: 1, connect_poll_ms: 50, reconnect: false)
    fake_peripheral_class.new(
      connect_delay: connect_delay,
      ticks_per_session: ticks_per_session,
      sessions: sessions,
      idle_ms: idle_ms,
      connect_poll_ms: connect_poll_ms,
      reconnect: reconnect
    )
  end

  # host の代わり。connected? を「繋がるまでに待たされる回数」と
  # 「繋がっていられる tick 数」と「何セッション分の host がいるか」で作る。
  private def fake_peripheral_class
    Class.new(USB::Peripheral) do
      attr_reader :log, :idles, :pumps, :waits, :session_count

      def initialize(connect_delay:, ticks_per_session:, sessions:,
                     idle_ms:, connect_poll_ms:, reconnect:)
        super(idle_ms: idle_ms, connect_poll_ms: connect_poll_ms, reconnect: reconnect)
        @connect_delay = connect_delay
        @ticks_per_session = ticks_per_session
        @sessions = sessions
        @log = []
        @idles = []
        @pumps = 0
        @waits = 0
        @waited = 0
        @session_count = 0
        @in_session = false
        @ticks_left = 0
      end

      def connected?
        if @in_session
          if 0 < @ticks_left
            @ticks_left -= 1
            return true
          end
          @in_session = false
          return false
        end
        if @waited < @connect_delay
          @waited += 1
          @waits += 1
          return false
        end
        return false if @sessions <= @session_count
        @waited = 0
        @session_count += 1
        @in_session = true
        @ticks_left = @ticks_per_session
        true
      end

      def restore_host_state
        @log << :restore
      end

      def pump
        @pumps += 1
      end

      def idle(ms)
        @idles << ms
      end
    end
  end
end
