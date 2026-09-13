require "usb/peripheral"

module USB
  class Peripheral
    # USB HID のマウス。firmware の descriptor に元から居る mouse インタフェースを使う。
    #
    #   USB::Peripheral::HIDMouse.new.run do |dev|
    #     dev.tick do |d|
    #       d.press(:left)
    #       d.wait(50)
    #       d.release(:left)
    #     end
    #   end
    #
    # 押しっぱなしのボタンは #restore_host_state が離すので、
    # ループを抜けたときに host 側へボタンを残さない。
    class HIDMouse < Peripheral
      # HID mouse report の buttons の bit
      BUTTONS = { left: 1, right: 2, middle: 4 }
      # 片付けの release を送り直す上限。endpoint が塞がっていても数 ms で空く。
      RELEASE_ATTEMPTS = 50

      def initialize(idle_ms: DEFAULT_IDLE_MS,
                     connect_poll_ms: DEFAULT_CONNECT_POLL_MS,
                     reconnect: true,
                     hid: nil)
        super(idle_ms: idle_ms, connect_poll_ms: connect_poll_ms, reconnect: reconnect)
        @hid = hid || default_hid
        @held = []
      end

      attr_reader :hid

      # host が USB 機器として構成済みか。HID は CDC と違って host 側が port を
      # 開くことが無いので、mount されているかで見る。
      def connected?
        Machine.tud_mounted?
      end

      # 押しているボタンの一覧。
      def held
        @held.dup
      end

      # 送れなかったら false を返し、押したことにはしない。
      def press(button)
        mask_of(button)
        buttons = @held.include?(button) ? @held : @held + [button]
        return false unless send_report(0, 0, buttons)
        @held = buttons
        true
      end

      # 送れなかったら false を返し、押したままにしておく。
      def release(button)
        mask_of(button)
        buttons = @held - [button]
        return false unless send_report(0, 0, buttons)
        @held = buttons
        true
      end

      # 押しているボタンは押したまま動かす。
      def move(dx, dy)
        send_report(dx, dy, @held)
      end

      # host に残した押しっぱなしのボタンを離す。
      def restore_host_state
        return nil if @held.empty?
        RELEASE_ATTEMPTS.times do
          if send_report(0, 0, [])
            @held = []
            return nil
          end
          wait(1)
        end
        nil
      end

      private

      def send_report(dx, dy, buttons)
        mask = 0
        buttons.each { |b| mask |= mask_of(b) }
        @hid.mouse_move(dx, dy, 0, mask)
      end

      def mask_of(button)
        BUTTONS[button] or raise ArgumentError, "unknown mouse button: #{button.inspect}"
      end

      def default_hid
        require "usb/hid"
        USB::HID
      end
    end
  end
end
