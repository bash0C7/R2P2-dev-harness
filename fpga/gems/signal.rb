# FPGA 版の Signal (PicoRuby の picoruby-signal の trap)。ボードにはシグナル (Ctrl-C) が届かないので、handler を覚えて
# 前のものを返すだけ (呼ばれることは無い)
module Signal
  HANDLERS = {}

  def self.trap(sig, command = nil, &block)
    prev = HANDLERS[sig]
    HANDLERS[sig] = block || command
    prev
  end
end
