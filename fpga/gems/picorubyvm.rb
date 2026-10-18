# FPGA 版の PicoRubyVM と ObjectSpace (PicoRuby の picoruby-picorubyvm)。コアはヒープの使い方を数えていないので、
# 数を返すメソッドは NotImplementedError (PicoRuby の gem は $DEBUG の時だけ呼ぶ)
module PicoRubyVM
  def self.memory_statistics
    raise NotImplementedError, "PicoRubyVM.memory_statistics is not available on the FPGA core"
  end
end

module ObjectSpace
  def self.count_objects
    raise NotImplementedError, "ObjectSpace.count_objects is not available on the FPGA core"
  end
end
