# .mrb -> ROM イメージの変換器の入口。PicoRuby (host VM) で走らせる:
#
#   picoruby tools/fpga/isa.rb,tools/fpga/io_map.rb,tools/fpga/rite.rb,tools/fpga/rom.rb,tools/fpga/mrb2rom.rb \
#            <in.mrb> <out.hex> <out.lst> [max_regs]
#
# PicoRuby には require が無いので、使う file を `,` でつないで渡す (rake の fpga_mrb2rom がそうする)。
# 成功すると "ok <語数> words, nregs <n>" を出す。変換できない時は理由を出して exit 1。
if ARGV.size < 3
  STDERR.puts "usage: picoruby isa.rb,io_map.rb,rite.rb,rom.rb,mrb2rom.rb <in.mrb> <out.hex> <out.lst> [max_regs]"
  exit 2
end

src = ARGV[0]
max_regs = ARGV[3] ? ARGV[3].to_i : nil
bin = File.open(src, "rb") { |f| f.read }

begin
  image = FpgaRom.from_binary(bin, src, max_regs)
rescue FpgaRom::Error, Rite::Error => e
  STDERR.puts e.message
  exit 1
end

File.open(ARGV[1], "w") { |f| f.write(image.hex) }
File.open(ARGV[2], "w") { |f| f.write(image.listing) }
puts "ok #{image.words.size} words, nregs #{image.nregs}"
