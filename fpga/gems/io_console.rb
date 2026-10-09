# FPGA 版の io/console。API は PicoRuby の picoruby-io-console (mrblib/io-console.rb) のうち、端末を持たない所。
# console の入力は UART の RX (tools/fpga/devices.rb の UART_RX、0x121) だとみなす。raw / cooked は何もしない。
class IO
  def initialize(fd = 0)
    @fd = fd
    @echo = true
  end

  # 受けたバイトを n まで (無ければ nil)
  def read_nonblock(n)
    s = ""
    while s.bytesize < n
      b = __io_read(0x121)
      break if b < 0
      s << b.chr
    end
    s.empty? ? nil : s
  end

  def getch
    while true
      c = read_nonblock(1)
      return c unless c.nil?
      sleep_ms 1
    end
  end

  def raw(&block)
    block.call(self)
  end

  def cooked(&block)
    block.call(self)
  end

  def raw!
    self
  end

  def cooked!
    self
  end

  def echo?
    @echo
  end

  def echo=(mode)
    @echo = mode
  end

  def self.clear_screen
    print "\e[2J\e[1;1H"
    nil
  end

  def self.get_cursor_position
    [24, 80]
  end
end

STDIN = IO.new(0)
