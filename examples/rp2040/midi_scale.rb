# USB MIDI デバイスとして、繋がっている間ドレミを昇り続ける。
#
#   ruby <harness>/tools/pmput.rb examples/rp2040/midi_scale.rb /home/midi_scale.rb
#
# Ctrl-C で抜けても、鳴っている note は器が止めるので host に stuck note を残さない。
require "usb/peripheral/cdc_midi"

USB::Peripheral::CDCMIDI.new(idle_ms: 0).run do |dev|
  note = 60

  dev.setup do
    puts "USB MIDI connected"
  end

  dev.tick do |d|
    d.note_on(0, note, 100)
    d.wait(180)   # 素の idle で止めると、その間 USB task が回らない
    d.note_off(0, note)
    note = 72 <= note ? 60 : note + 1
  end

  dev.teardown do
    puts "USB MIDI disconnected"
  end
end
