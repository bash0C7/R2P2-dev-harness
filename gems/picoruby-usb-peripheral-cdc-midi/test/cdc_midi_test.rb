# USB::Peripheral::CDCMIDI。USB へは書かず、書かれたイベントを控える output で回す。
#
# USB の定数に触る fake は method の中で Class.new する。runner が test file を
# まず CRuby で load するので、top level で触るとその時点で NameError になる。
class USBPeripheralCDCMIDITest < Picotest::Test

  def test_connected_follows_the_output
    output = fake_output(connected: false)
    dev = USB::Peripheral::CDCMIDI.new(output: output, reconnect: false)
    assert_equal false, dev.connected?
    output.connected = true
    assert_equal true, dev.connected?
  end

  def test_note_on_is_written_and_remembered
    dev = build_device
    assert_equal 3, dev.note_on(0, 60, 100)
    assert_equal [[:note_on, 0, 60, 100]], dev.output.events
    assert_equal [[0, 60]], dev.sounding
  end

  def test_note_off_forgets_the_note
    dev = build_device
    dev.note_on(0, 60)
    dev.note_off(0, 60)
    assert_equal [], dev.sounding
    assert_equal [[:note_on, 0, 60, 100], [:note_off, 0, 60, 0]], dev.output.events
  end

  def test_a_note_is_remembered_once_per_channel_and_pitch
    dev = build_device
    dev.note_on(0, 60)
    dev.note_on(0, 60)
    dev.note_on(1, 60)
    assert_equal [[0, 60], [1, 60]], dev.sounding
  end

  def test_a_note_that_was_not_written_is_not_remembered
    dev = build_device(connected: false)
    assert_equal false, dev.note_on(0, 60)
    assert_equal [], dev.sounding
  end

  def test_restore_host_state_releases_every_sounding_note
    dev = build_device
    dev.note_on(0, 60)
    dev.note_on(1, 64)
    dev.output.events.clear
    dev.restore_host_state
    assert_equal [[:note_off, 0, 60, 0], [:note_off, 1, 64, 0]], dev.output.events
    assert_equal [], dev.sounding
  end

  def test_restore_host_state_is_quiet_when_nothing_sounds
    dev = build_device
    dev.restore_host_state
    assert_equal [], dev.output.events
  end

  def test_putevent_goes_straight_through
    dev = build_device
    dev.putevent(:pitch_bend, 2, 8192)
    assert_equal [[:pitch_bend, 2, 8192]], dev.output.events
    assert_equal [], dev.sounding
  end

  def test_leaving_the_loop_does_not_leave_a_stuck_note
    dev = build_running_device
    dev.tick do |d|
      d.note_on(0, 60)
      d.stop
    end
    dev.run
    assert_equal [[:note_on, 0, 60, 100], [:note_off, 0, 60, 0]], dev.output.events
    assert_equal [], dev.sounding
  end

  def test_a_raise_in_tick_does_not_leave_a_stuck_note_either
    dev = build_running_device
    dev.tick do |d|
      d.note_on(0, 60)
      raise ArgumentError, "boom"
    end
    assert_raise(ArgumentError) { dev.run }
    assert_equal [[:note_on, 0, 60, 100], [:note_off, 0, 60, 0]], dev.output.events
  end

  # ライフサイクルを回さない素の CDCMIDI
  private def build_device(connected: true)
    USB::Peripheral::CDCMIDI.new(output: fake_output(connected: connected), reconnect: false)
  end

  # run まで回すための、下回りだけを差し替えた CDCMIDI
  private def build_running_device(ticks: 1)
    testable_cdc_midi_class.new(output: fake_output(connected: true), ticks: ticks)
  end

  # USB へは書かず、書かれたイベントを控えるだけの MIDIOutput。
  # 戻り値は本物と同じく「書いたバイト数」を模して values の数にする。
  private def fake_output(connected:)
    Class.new do
      attr_reader :events
      attr_accessor :connected

      def initialize(connected)
        @connected = connected
        @events = []
      end

      def connected?
        @connected
      end

      def putevent(command, *values)
        return false unless @connected
        event = [command]
        values.each { |v| event << v }
        @events << event
        values.size
      end
    end.new(connected)
  end

  # connected? は output に従いつつ、指定した tick 数で切断したことにする。
  private def testable_cdc_midi_class
    Class.new(USB::Peripheral::CDCMIDI) do
      def initialize(output:, ticks:)
        super(output: output, reconnect: false, idle_ms: 0, connect_poll_ms: 0)
        @ticks_left = ticks
        @in_session = false
      end

      def connected?
        return false unless super
        unless @in_session
          @in_session = true
          return true
        end
        return false if @ticks_left <= 0
        @ticks_left -= 1
        true
      end

      def pump
        nil
      end

      def idle(_ms)
        nil
      end
    end
  end
end
