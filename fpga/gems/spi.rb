# FPGA 版の spi gem。API は PicoRuby の picoruby-spi (mrblib/spi.rb、sig/spi.rbs、src/mruby/spi.c) と同じ。
# 送るバイトはデバイスの SPI_TX (0x190) へ1つずつ、返事は SPI_RX (0x191、シミュレーションでは刺激) から。CS は GPIO。
class SPI
  MSB_FIRST = 1
  LSB_FIRST = 0
  DATA_BITS = 8
  DEFAULT_FREQUENCY = 100_000

  attr_accessor :unit, :cs

  def initialize(unit: nil, frequency: DEFAULT_FREQUENCY, sck_pin: -1, cipo_pin: -1, copi_pin: -1, cs_pin: -1, mode: 0,
                 first_bit: MSB_FIRST)
    @unit = unit.to_s
    @sck_pin = sck_pin
    @cipo_pin = cipo_pin
    @copi_pin = copi_pin
    @cs_pin = cs_pin
    if -1 < cs_pin
      cs = GPIO.new(cs_pin, GPIO::OUT)
      cs.write(1)
      @cs = cs
    end
  end

  def sck_pin
    @sck_pin
  end

  def cipo_pin
    @cipo_pin
  end

  def copi_pin
    @copi_pin
  end

  def cs_pin
    @cs_pin
  end

  def select
    @cs&.write 0
    if block_given?
      begin
        yield self
      ensure
        deselect
      end
    end
  end

  def deselect
    @cs&.write 1
  end

  def __spi_bytes(outputs)
    bytes = []
    outputs.each do |o|
      if o.is_a?(Integer)
        bytes << (o & 0xFF)
      elsif o.is_a?(String)
        o.bytes.each { |b| bytes << b }
      elsif o.is_a?(Array)
        o.each do |b|
          raise TypeError, "array element must be Fixnum" unless b.is_a?(Integer)
          bytes << (b & 0xFF)
        end
      else
        raise ArgumentError, "argument must be Integer, Array or String"
      end
    end
    bytes
  end

  def write(*outputs)
    bytes = __spi_bytes(outputs)
    bytes.each { |b| __io_write(0x190, b) }
    bytes.size
  end

  def read(len, repeated_tx_data = 0)
    s = ""
    len.times do
      __io_write(0x190, repeated_tx_data & 0xFF)
      s << __io_read(0x191).chr
    end
    s
  end

  def transfer(*outputs, additional_read_bytes: 0)
    s = ""
    __spi_bytes(outputs).each do |b|
      __io_write(0x190, b)
      s << __io_read(0x191).chr
    end
    additional_read_bytes.times do
      __io_write(0x190, 0)
      s << __io_read(0x191).chr
    end
    s
  end
end
