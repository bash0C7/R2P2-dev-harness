require_relative "test_helper"
require_relative "psg_decode"

class FpgaPsgDecodeTest < Minitest::Test
  # P 行: {op, reg, val, arg} と aux。voice_write (op 6) は {6, 声, 音量, mixer << 6 | noise}、aux = トーンの周期
  def p_line(ms, op, reg, val, arg, aux = 0)
    format("P 0 %d %08x %04x", ms, (op << 24) | (reg << 16) | (val << 8) | arg, aux)
  end

  def test_voice_writes_become_notes
    trace = [
      "O 0 421 3 00000001",               # 0x1A5 = 1 (PWM を選ぶ。全部の声を mute から)
      p_line(0, 4, 0, 1, 0),              # 声 0 は三角波
      p_line(0, 6, 0, 15, 1 << 6, 179),   # 62500 / 179 = 349.2 Hz (F4)
      p_line(500, 6, 0, 15, 1 << 6, 119), # 525.2 Hz (C5)
      p_line(1000, 6, 0, 0, 0, 0),        # 音量 0 は止める
      p_line(1000, 0x81, 1, 0, 0)         # 列を通さない mute の解除だけでは鳴らない (トーンの周期が 0)
    ]
    ev = FpgaPsg.from_trace(trace)
    assert_equal [[0, 0, ["F4", 349.2, 15, "triangle"]], [500, 0, ["C5", 525.2, 15, "triangle"]], [1000, 0, nil]], ev
    assert_match(/0.500 s  psg0   C5/, FpgaPsg.format_events(ev)[1])
  end

  # レジスタへの書き込み (op 0): トーンの周期 (0 と 1)、音量 (8)。mute を解いてから鳴る
  def test_register_writes
    trace = [p_line(0, 0, 0, 0xB3, 0), p_line(0, 0, 1, 0x00, 0), p_line(0, 0, 8, 12, 0), p_line(10, 2, 0, 0, 0)]
    assert_equal [[10, 0, ["F4", 349.2, 12, "square"]]], FpgaPsg.from_trace(trace)
  end
end
