# FPGA 版の i2c gem。API は PicoRuby の picoruby-i2c (mrblib/i2c.rb と src/mruby/i2c.c) と同じ。
# 送受信はデバイス (tools/fpga/devices.rb の I2C_*、0x180 から): 番地を書き、応答しなければ IOError、送るバイトは1つずつ、
# 返事は I2C_RX から (シミュレーションでは刺激)。unit は1つ。
class I2C
  DEFAULT_FREQUENCY = 100_000 # Hz
  DEFAULT_TIMEOUT = 500 # ms

  def initialize(unit: nil, frequency: DEFAULT_FREQUENCY, sda_pin: -1, scl_pin: -1, timeout: DEFAULT_TIMEOUT)
    @timeout = timeout
    @unit_num = 0
  end

  # Integer / String / Array[Integer] を並べたバイトの列
  def __i2c_bytes(outputs)
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
        raise TypeError, "argument must be Integer, Array or String"
      end
    end
    bytes
  end

  # 応答しなければ -1、送ったら数。nostop なら終わりを送らない
  def __i2c_write(i2c_adrs_7, bytes, nostop)
    __io_write(0x180, i2c_adrs_7)
    if __io_read(0x182) == 0
      __io_write(0x183, 0)
      return -1
    end
    bytes.each { |b| __io_write(0x181, b) }
    __io_write(0x183, 0) unless nostop
    bytes.size
  end

  def write(i2c_adrs_7, *outputs, timeout: @timeout, nostop: false)
    n = __i2c_write(i2c_adrs_7, __i2c_bytes(outputs), nostop)
    raise IOError, "I2C write failed" if n < 0
    n
  end

  def read(i2c_adrs_7, len, *outputs, timeout: @timeout)
    if outputs.size > 0
      raise IOError, "I2C write (for read) failed" if __i2c_write(i2c_adrs_7, __i2c_bytes(outputs), true) < 0
    end
    __io_write(0x180, i2c_adrs_7)
    ack = __io_read(0x182)
    s = ""
    if ack == 1
      len.times { s << __io_read(0x184).chr }
    end
    __io_write(0x183, 0)
    raise IOError, "I2C read failed" if ack == 0 || len <= 0
    s
  end

  def scan(timeout: @timeout)
    msg_format = "I2C device found at 7-bit address 0x%02x (0b%07b) +%s"
    i2c_adrs_7 = 0x08
    while i2c_adrs_7 <= 0x77
      begin
        read(i2c_adrs_7, 1, timeout: timeout)
        puts sprintf(msg_format, i2c_adrs_7, i2c_adrs_7, "R")
      rescue IOError => e
        # p e
      end
      begin
        write(i2c_adrs_7, 0, timeout: timeout)
        puts sprintf(msg_format, i2c_adrs_7, i2c_adrs_7, "W")
      rescue IOError => e
        # p e
      end
      i2c_adrs_7 += 1
    end
    nil
  end
end
