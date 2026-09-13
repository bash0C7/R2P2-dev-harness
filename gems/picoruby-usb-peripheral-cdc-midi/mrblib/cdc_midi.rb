require "usb/peripheral"
require "usb/cdc/midi"

module USB
  class Peripheral
    # MIDI over USB CDC。descriptor の変更が要らない唯一の USB 経路なので、
    # 器の第1号がこれになっている。
    #
    #   USB::Peripheral::CDCMIDI.new.run do |dev|
    #     note = 60
    #     dev.tick do
    #       dev.note_on(0, note, 100)
    #       dev.idle(180)
    #       dev.note_off(0, note)
    #       note = 72 <= note ? 60 : note + 1
    #     end
    #   end
    #
    # 鳴らしっぱなしの note は #restore_host_state が片付けるので、
    # ループを抜けたときに host 側へ stuck note を残さない。
    class CDCMIDI < Peripheral
      DEFAULT_VELOCITY = 100

      def initialize(idle_ms: DEFAULT_IDLE_MS,
                     connect_poll_ms: DEFAULT_CONNECT_POLL_MS,
                     reconnect: true,
                     write_timeout_ms: USB::CDC::MIDIOutput::DEFAULT_WRITE_TIMEOUT_MS,
                     output: nil)
        super(idle_ms: idle_ms, connect_poll_ms: connect_poll_ms, reconnect: reconnect)
        @output = output || USB::CDC::MIDIOutput.new(write_timeout_ms: write_timeout_ms)
        @sounding = []
      end

      attr_reader :output

      def connected?
        @output.connected?
      end

      # 鳴っている note の [channel, note] の一覧。
      def sounding
        @sounding.dup
      end

      def note_on(channel, note, velocity = DEFAULT_VELOCITY)
        written = @output.putevent(:note_on, channel, note, velocity)
        remember(channel, note) if written
        written
      end

      def note_off(channel, note)
        written = @output.putevent(:note_off, channel, note, 0)
        forget(channel, note)
        written
      end

      def putevent(command, *values)
        @output.putevent(command, *values)
      end

      # host に残した鳴りっぱなしの note を戻す。
      def restore_host_state
        return nil if @sounding.empty?
        @sounding.dup.each do |pair|
          note_off(pair[0], pair[1])
        end
        @sounding.clear
        nil
      end

      private

      def remember(channel, note)
        pair = [channel, note]
        @sounding << pair unless @sounding.include?(pair)
      end

      def forget(channel, note)
        @sounding.delete([channel, note])
      end
    end
  end
end
