# FPGA 版の uart gem。API は PicoRuby の picoruby-uart (mrblib/uart.rb と src/mruby/uart.c) と同じ。
# 送信は1バイトずつデバイスの UART_TX (0x120) へ、受信は UART_RX (0x121) から読んで Ruby の buffer に貯めてから返す
# (gets が行の終わりを探すため)。unit は1つだけ (どの unit も同じ UART)。
class UART
  PARITY_NONE = 0
  PARITY_EVEN = 1
  PARITY_ODD = 2
  FLOW_CONTROL_NONE = 0
  FLOW_CONTROL_RTS_CTS = 1
  RX_RECEIVE = 1

  def initialize(unit: nil, txd_pin: -1, rxd_pin: -1, baudrate: 9600, data_bits: 8, stop_bits: 1,
                 parity: PARITY_NONE, flow_control: FLOW_CONTROL_NONE, rts_pin: -1, cts_pin: -1, rx_buffer_size: nil)
    @unit = unit
    @buf = ""
    @line_ending = "\n"
    setmode(baudrate: baudrate, data_bits: data_bits, stop_bits: stop_bits, parity: parity,
            flow_control: flow_control, rts_pin: rts_pin, cts_pin: cts_pin)
  end

  attr_reader :baudrate

  def setmode(baudrate: nil, data_bits: nil, stop_bits: nil, parity: nil, flow_control: nil, rts_pin: nil, cts_pin: nil)
    if baudrate
      @baudrate = baudrate
      __io_write(0x123, baudrate)
    end
    if flow_control == FLOW_CONTROL_RTS_CTS && (rts_pin || -1) < 0 && (cts_pin || -1) < 0
      raise ArgumentError, "UART: RTS and CTS pins must be specified for hardware flow control"
    end
    raise ArgumentError, "UART: invalid flow control mode" unless flow_control.nil? || flow_control == FLOW_CONTROL_NONE || flow_control == FLOW_CONTROL_RTS_CTS
    self
  end

  def line_ending=(line_ending)
    raise ArgumentError, "UART: invalid line ending" unless ["\n", "\r", "\r\n"].include?(line_ending)
    @line_ending = line_ending
  end

  def write(str)
    i = 0
    n = str.bytesize
    while i < n
      __io_write(0x120, str.getbyte(i))
      i += 1
    end
    n
  end

  def puts(str)
    write(str)
    write(@line_ending) unless str.end_with?(@line_ending)
    nil
  end

  def putc(ch)
    if ch.is_a?(Integer)
      __io_write(0x120, ch & 0xFF)
    elsif ch.is_a?(String)
      write(ch[0]) unless ch.empty?
    else
      raise TypeError, "wrong argument type (expected Integer or String)"
    end
    ch
  end

  # 届いたバイトを buffer へ
  def __fill
    while __io_read(0x122) > 0
      @buf << __io_read(0x121).chr
    end
    @buf
  end

  def bytes_available
    __fill.bytesize
  end

  def read(len = nil)
    __fill
    return nil if @buf.empty? || (len && @buf.bytesize < len)
    __take(len || @buf.bytesize)
  end

  def readpartial(maxlen)
    __fill
    return nil if @buf.empty?
    __take(maxlen < @buf.bytesize ? maxlen : @buf.bytesize)
  end

  def getbyte
    __fill
    return nil if @buf.empty?
    __take(1).getbyte(0)
  end

  def ungetbyte(byte)
    @buf = (byte & 0xFF).chr + @buf
    nil
  end

  def gets
    i = __fill.index("\n")
    i ? __take(i + 1) : nil
  end

  def __take(n)
    s = @buf[0, n]
    @buf = @buf[n, @buf.bytesize - n]
    s
  end

  def flush
    self
  end

  def clear_tx_buffer
    self
  end

  def clear_rx_buffer
    __fill
    @buf = ""
    self
  end
end
