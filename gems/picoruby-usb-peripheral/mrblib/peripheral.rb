module USB
  # USB 周辺機器の器。
  #
  # 初期化・メインループ・片付けにそれぞれメソッドがあり、具体の処理はブロックで渡す。
  # 接続待ち、USB task の駆動、切断の検出、例外時の後始末はここが持つ。
  #
  #   dev = USB::Peripheral::CDCMIDI.new
  #   dev.setup    { |d| ... }
  #   dev.tick     { |d| ... }
  #   dev.teardown { |d| ... }
  #   dev.run
  #
  # subclass が実装するのは #connected? と #restore_host_state の2つ。
  class Peripheral
    class Error < StandardError; end
    class NotImplementedByPort < Error; end

    DEFAULT_IDLE_MS = 1
    DEFAULT_CONNECT_POLL_MS = 50

    def initialize(idle_ms: DEFAULT_IDLE_MS,
                   connect_poll_ms: DEFAULT_CONNECT_POLL_MS,
                   reconnect: true)
      @idle_ms = idle_ms
      @connect_poll_ms = connect_poll_ms
      @reconnect = reconnect
      @setup_block = nil
      @tick_block = nil
      @teardown_block = nil
      @stopped = false
    end

    attr_reader :idle_ms, :connect_poll_ms

    def reconnect?
      @reconnect
    end

    def setup(&block)
      @setup_block = block
      self
    end

    def tick(&block)
      @tick_block = block
      self
    end

    def teardown(&block)
      @teardown_block = block
      self
    end

    # tick の中から呼ぶとループを抜ける。
    def stop
      @stopped = true
      self
    end

    def stopped?
      @stopped
    end

    # host が繋がるのを待ち、繋がっている間 tick を回す。
    # 切断されたら後始末をして、reconnect: true なら再び待つ。
    def run
      yield self if block_given?
      raise Error, "no tick block given" unless @tick_block

      @stopped = false
      until @stopped
        wait_for_connection
        break if @stopped
        session
        break unless @reconnect
      end
      self
    end

    # --- subclass が実装する ---

    def connected?
      raise NotImplementedByPort, "#{self.class} must implement #connected?"
    end

    # host に残した状態を戻す。鳴りっぱなしの note、押しっぱなしのボタン。
    # USB を畳むためのものではない。
    def restore_host_state
      nil
    end

    # --- 下回り。テストではここを差し替える ---

    def pump
      Machine.tud_task
    end

    def idle(ms)
      sleep_ms ms
    end

    private

    def wait_for_connection
      until @stopped || connected?
        pump
        idle(@connect_poll_ms)
      end
    end

    def session
      @setup_block.call(self) if @setup_block
      while !@stopped && connected?
        @tick_block.call(self)
        pump
        idle(@idle_ms) if 0 < @idle_ms
      end
    ensure
      restore_host_state
      @teardown_block.call(self) if @teardown_block
    end
  end
end
