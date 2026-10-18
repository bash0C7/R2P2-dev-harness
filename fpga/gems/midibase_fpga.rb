# midibase (PicoRuby の mrblib をそのまま使う) の MIDIBASE を include するクラスが定義するメソッド。定義していないクラスで
# 呼ばれた時は PicoRuby と同じく NoMethodError (FPGA の変換器がメソッドの無い呼び出しを変換で止めないように置く)
module MIDIBASE
  def midi_read_byte
    raise NoMethodError, "undefined method 'midi_read_byte' for #{self.class}"
  end

  def midi_read_timestamp_us
    raise NoMethodError, "undefined method 'midi_read_timestamp_us' for #{self.class}"
  end

  def midi_write_byte(_byte)
    raise NoMethodError, "undefined method 'midi_write_byte' for #{self.class}"
  end
end
