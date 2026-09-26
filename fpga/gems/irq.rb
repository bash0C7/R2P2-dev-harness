# FPGA 版の irq gem。API は PicoRuby の picoruby-irq (mrblib/irq.rb と sig/irq.rbs) のうち、ポーリング (IRQ.process) で使う所。
# 枠と事象の列はデバイス (tools/fpga/devices.rb の IRQ_*、0x160 から。RP2040 の port と同じ 16 枠・列 32) が持つ。
# IRQ.start / stop は Task が要る (FPGA では P6)。
module IRQ
  MAX_PROCESS_COUNT = 5
  HANDLER = {}

  def self.register_gpio(pin, event_type, opts)
    d = opts[:debounce]
    __io_write(0x160, pin)
    __io_write(0x161, event_type)
    __io_write(0x162, d.nil? ? 0 : d)
    id = __io_read(0x163)
    raise RuntimeError, "Failed to register GPIO IRQ" if id < 0
    id
  end

  def self.unregister_gpio(id)
    __io_write(0x164, id)
    __io_read(0x165) == 1
  end

  # [id, 事象] (列が空なら [nil, 0])。取った事象は列から消える
  def self.peek_event
    v = __io_read(0x166)
    v < 0 ? [nil, 0] : [v >> 8, v & 0xFF]
  end

  def self.unregister(id)
    irq = HANDLER.delete(id)
    raise "IRQ not registered: #{id}" unless irq
    unregister_gpio(id)
  end

  def self.register(irq, opts)
    peri = irq.peripheral
    raise NotImplementedError, "IRQ: #{peri.class} has no event source in this build" unless peri.is_a?(GPIO)
    id = register_gpio(peri.pin, irq.event_type, opts)
    HANDLER[id] = irq
    id
  end

  # 渡した事象の数。上限は peek_event の前に見る (取った事象を捨てないため)
  def self.process(max_count = MAX_PROCESS_COUNT)
    count = 0
    while count < max_count
      id, event_type = peek_event
      break if id.nil?
      irq = HANDLER[id]
      if irq
        irq.call(event_type)
        count += 1
      end
    end
    count
  end

  def self.start
    raise NotImplementedError, "IRQ.start needs Task, which the FPGA core does not have yet"
  end

  def self.stop
    false
  end

  def irq(event_type, **opts, &callback)
    IRQInstance.new(self, event_type, opts, callback)
  end

  class IRQInstance
    def initialize(peripheral, event_type, opts, callback)
      @peripheral = peripheral
      @callback = callback
      @event_type = event_type
      @enabled = true
      @capture = opts.delete(:capture)
      @id = IRQ.register(self, opts)
    end

    attr_accessor :capture
    attr_reader :peripheral, :event_type

    def call(event_type)
      return unless @enabled
      @callback&.call(@peripheral, event_type, @capture)
    end

    def enabled?
      @enabled
    end

    def enable
      previous = @enabled
      @enabled = true
      previous
    end

    def disable
      previous = @enabled
      @enabled = false
      previous
    end

    def unregister
      IRQ.unregister(@id)
    end
  end
end

class GPIO
  include IRQ
end
