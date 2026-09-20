# USB MIDI デバイスとして、繋がっている間ドレミを昇り続ける。
#
#   ruby <harness>/tools/pmput.rb examples/rp2040/midi_scale.rb /home/midi_scale.rb
#
# tick の中で例外が raise されて抜けた時は、鳴っている note を器が止める。
# ただし Ctrl-C (rake rp2040:run が最後に送るものを含む) はこの teardown を
# 経由しない — 音が鳴っている瞬間に Ctrl-C で止めると host に stuck note が
# 残り得る (issue #14, docs/spec.md §2)。
require "usb/peripheral/cdc_midi"

USB::Peripheral::CDCMIDI.new(idle_ms: 0).run do |dev|
  note = 60

  dev.setup do
    puts "USB MIDI connected"
  end

  dev.tick do |d|
    d.note_on(0, note, 100)
    d.wait(180)   # 長く待つときの入口。rp2040 では sleep とほぼ同じだが、port を跨ぐ
    d.note_off(0, note)
    note = 72 <= note ? 60 : note + 1
  end

  dev.teardown do
    puts "USB MIDI disconnected"
  end
end
