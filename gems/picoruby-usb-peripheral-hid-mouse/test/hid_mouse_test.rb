# USB::Peripheral::HIDMouse。USB へは送らず、送られた report を控える hid で回す。
#
# USB の定数に触る fake は method の中で Class.new する。runner が test file を
# まず CRuby で load するので、top level で触るとその時点で NameError になる。
class USBPeripheralHIDMouseTest < Picotest::Test

  def test_press_sends_the_button_and_remembers_it
    dev = build_device
    assert_equal true, dev.press(:left)
    assert_equal [[0, 0, 0, 1]], dev.hid.reports
    assert_equal [:left], dev.held
  end

  def test_a_second_button_is_sent_together_with_the_held_one
    dev = build_device
    dev.press(:left)
    dev.press(:right)
    assert_equal [0, 0, 0, 3], dev.hid.reports.last
    assert_equal [:left, :right], dev.held
  end

  def test_release_sends_what_is_still_held
    dev = build_device
    dev.press(:left)
    dev.press(:middle)
    dev.release(:left)
    assert_equal [0, 0, 0, 4], dev.hid.reports.last
    assert_equal [:middle], dev.held
  end

  def test_pressing_a_held_button_again_does_not_repeat_it_in_held
    dev = build_device
    dev.press(:left)
    dev.press(:left)
    assert_equal [:left], dev.held
  end

  def test_an_unknown_button_is_rejected
    dev = build_device
    assert_raise(ArgumentError) { dev.press(:thumb) }
    assert_equal [], dev.hid.reports
  end

  def test_a_press_that_was_not_sent_is_not_remembered
    dev = build_device(busy: 1)
    assert_equal false, dev.press(:left)
    assert_equal [], dev.held
  end

  def test_a_release_that_was_not_sent_keeps_the_button_held
    dev = build_device
    dev.press(:left)
    dev.hid.busy = 1
    assert_equal false, dev.release(:left)
    assert_equal [:left], dev.held
  end

  def test_move_keeps_the_held_buttons_down
    dev = build_device
    dev.press(:left)
    dev.move(5, -3)
    assert_equal [5, -3, 0, 1], dev.hid.reports.last
  end

  def test_restore_host_state_releases_every_held_button
    dev = build_device
    dev.press(:left)
    dev.press(:right)
    dev.hid.reports.clear
    dev.restore_host_state
    assert_equal [[0, 0, 0, 0]], dev.hid.reports
    assert_equal [], dev.held
  end

  def test_restore_host_state_is_quiet_when_nothing_is_held
    dev = build_device
    dev.restore_host_state
    assert_equal [], dev.hid.reports
  end

  # 送信中の endpoint は report を受け付けない。片付けの release を落とすと
  # host にボタンが押しっぱなしで残るので、空くまで待って送り直す。
  def test_restore_host_state_retries_while_the_endpoint_is_busy
    dev = build_running_device
    dev.press(:left)
    dev.hid.busy = 3
    dev.restore_host_state
    assert_equal [0, 0, 0, 0], dev.hid.reports.last
    assert_equal [], dev.held
  end

  def test_leaving_the_loop_does_not_leave_a_held_button
    dev = build_running_device
    dev.tick do |d|
      d.press(:left)
      d.stop
    end
    dev.run
    assert_equal [[0, 0, 0, 1], [0, 0, 0, 0]], dev.hid.reports
    assert_equal [], dev.held
  end

  def test_a_raise_in_tick_does_not_leave_a_held_button_either
    dev = build_running_device
    dev.tick do |d|
      d.press(:left)
      raise ArgumentError, "boom"
    end
    assert_raise(ArgumentError) { dev.run }
    assert_equal [[0, 0, 0, 1], [0, 0, 0, 0]], dev.hid.reports
  end

  # ここだけ fake を使わない。hid を渡さない経路は USB::HID を既定にするが、
  # ホストの test VM に picoruby-usb-hid は居ない (C の実体が rp2040 にしか無い)。
  # connected? がホストの Machine.tud_mounted? (posix port では true) に従うことだけ見る。
  def test_connected_follows_tud_mounted
    dev = USB::Peripheral::HIDMouse.new(hid: fake_hid(busy: 0), reconnect: false)
    assert_equal Machine.tud_mounted?, dev.connected?
  end

  # ライフサイクルを回さない素の HIDMouse
  private def build_device(busy: 0)
    USB::Peripheral::HIDMouse.new(hid: fake_hid(busy: busy), reconnect: false)
  end

  # run まで回すための、下回りだけを差し替えた HIDMouse。1 tick で切断したことにする。
  private def build_running_device
    testable_hid_mouse_class.new(hid: fake_hid(busy: 0))
  end

  # USB へは送らず、送られた report を控えるだけの USB::HID。
  # busy が残っている間は、本物の endpoint が塞がっているときと同じく false を返す。
  private def fake_hid(busy:)
    Class.new do
      attr_reader :reports
      attr_accessor :busy

      def initialize(busy)
        @busy = busy
        @reports = []
      end

      def mouse_move(x, y, wheel, buttons)
        if 0 < @busy
          @busy -= 1
          return false
        end
        @reports << [x, y, wheel, buttons]
        true
      end
    end.new(busy)
  end

  private def testable_hid_mouse_class
    Class.new(USB::Peripheral::HIDMouse) do
      def initialize(hid:)
        super(hid: hid, reconnect: false, idle_ms: 0, connect_poll_ms: 0)
        @in_session = false
      end

      def connected?
        return true unless @in_session
        false
      end

      def pump
        @in_session = true
        nil
      end

      def idle(_ms)
        nil
      end
    end
  end
end
