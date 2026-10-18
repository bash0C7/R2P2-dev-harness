# FPGA 版の picotest の C の所 (PicoRuby の picoruby-picotest の src/mruby/picotest.c)。板の上で走る Ruby の所 (picotest.rb、
# picotest/test.rb) は PicoRuby の mrblib をそのまま使う。
# Picotest::Double (stub / mock) は実行時にメソッドを定義するので、動的なメソッドの定義ができるまで (P9b) 無い。double.rb は
# 入れないので、stub / mock を使うプログラムは Double._init が無くて変換で止まる。remove_singleton は Test#clear_doubles が
# 毎回名前を引く (double が無ければ呼ばれない)
module Picotest
  class Double
    def remove_singleton
      raise NotImplementedError, "Picotest::Double (stub / mock) is not available on the FPGA core yet"
    end
  end
end
