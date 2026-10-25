# MML (P5e、P8): midibase-mml の Player が PSG の Synth に音を送る。音と音の間の待ち時間は
# delta_ticks * 60_000_000 / (ppqn * tempo) で、32bit の Integer では桁があふれる (64bit の Integer で正しい間隔になる)
require 'psg'
require 'midibase-mml'

driver = PSG::Driver.new(:pwm, left: 10, right: 11)
synth = PSG::Synth.new(driver).start
router = MIDIBASE::Router.new
router.connect(:mml, synth, priority: 0)
sequence = MIDIBASE::MML::Sequence.new(['@0 T120 L4 O5 f f >c c'])
player = MIDIBASE::MML::Player.new(sequence, output: router.output(:mml)).start
player.join
synth.stop.join
driver.join
puts "end"
