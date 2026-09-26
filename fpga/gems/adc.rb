# FPGA 版の adc gem。API は PicoRuby の picoruby-adc (mrblib/adc.rb と src/mruby/adc.c、ports/rp2040/adc.c) と同じ。
# 入力はピン 26..29 (0..3) と "temperature" (4)。値はデバイス (tools/fpga/devices.rb の ADC_BASE、0x150 から) の 12bit で、
# シミュレーションでは刺激で与える。
class ADC
  def initialize(pin, additional_params = {})
    @additional_params = additional_params
    @input = _init(pin)
    begin
      init_additional_params unless @additional_params.empty?
    rescue NoMethodError => e
      puts "You need to define `ADC#init_additional_params` if you use additional params"
      raise e
    end
  end

  attr_reader :input

  def _init(pin)
    n = if pin.is_a?(Integer)
          pin
        elsif (pin.is_a?(String) || pin.is_a?(Symbol)) && pin.to_s == "temperature"
          255
        else
          -1
        end
    raise ArgumentError, "Wrong ADC pin name: #{pin}" if n < 0 && !pin.is_a?(Integer)
    input = n == 255 ? 4 : (n >= 26 && n <= 29 ? n - 26 : -1)
    raise ArgumentError, "Wrong ADC pin value" if input < 0
    input
  end

  def read_raw
    __io_read(0x150 + @input)
  end

  def read_voltage
    read_raw.to_f * 3.3 / 4095
  end

  def read
    read_voltage
  end
end
