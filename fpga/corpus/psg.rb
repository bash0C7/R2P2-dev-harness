# PSG (P5e): 音程の表 (README の値: note_to_period(60) は 239、round: false は 238)、パケットの列 (遅延つきで積み、
# 仮想の時計の 1ms ごとに取り出される)、満杯、flush、deinit。音はトレースの P 行を psg_decode.rb が組み立てる
require "psg"

p PSG.note_to_period(60)
p PSG.note_to_period(60, round: false)
p PSG.note_to_period(69)
p PSG.note_to_period(60.5)
p PSG.note_to_period(130)
PSG.set_tuning(:just_c_major)
p PSG.note_to_period(64)
PSG.set_tuning(:equal, pitch: 442)
p PSG.note_to_period(69)
PSG.set_tuning

driver = PSG::Driver.new(:pwm, left: 10, right: 11)
driver.set_timbre(0, PSG::Driver::TIMBRES[:triangle])
driver.mute(0, 0)
driver.send_reg(8, 15)
[60, 64, 67, 72].each do |note|
  period = PSG.note_to_period(note)
  driver.send_reg(0, period & 0xFF, 250)
  driver.send_reg(1, period >> 8)
end
driver.voice_write(1, PSG.note_to_period(48), 0, 12, 1)
p driver.buffer_empty?
sleep_ms 600
p driver.buffer_empty?
sleep_ms 600
p driver.buffer_empty?

# 列は 255 まで
n = 0
n += 1 while driver.send_reg(9, 0, 1000)
p n
driver.buffer_flush
p driver.buffer_empty?
driver.mute_direct(0, 1)
driver.write_reg_direct(8, 0)
driver.deinit
p driver.send_reg(8, 1)
p driver.buffer_empty?
