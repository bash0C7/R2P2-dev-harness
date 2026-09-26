require "minitest/autorun"
require_relative "converter"

module FpgaTestHelper
  ROOT     = File.expand_path("../..", __dir__)
  CORPUS   = File.join(ROOT, "fpga", "corpus")
  VENDOR   = File.join(ROOT, "vendor", "picoruby")
  MRBC     = ENV["MRBC"] || File.join(VENDOR, "bin", "mrbc")
  PICORUBY = File.join(VENDOR, "bin", "picoruby")
  OPS_H    = File.join(VENDOR, "mrbgems", "picoruby-mruby", "lib", "mruby", "include", "mruby", "ops.h")

  # 最小の RITE0400 を組む。mrbc 無しで変換器のエラー経路を試すため。
  # reps: 子 irep (irep_record の返り値) の列
  def rite(iseq, nregs: 4, syms: [], plen: 0, reps: [])
    rec = irep_record(iseq, nregs: nregs, syms: syms, plen: plen, reps: reps)
    irep = "IREP" + [12 + rec.bytesize].pack("N") + "0400" + rec
    body = irep + "END\0" + [8].pack("N")
    "RITE0400" + [20 + body.bytesize].pack("N") + "MATZ0000" + body
  end
  
  def irep_record(iseq, nregs: 4, syms: [], plen: 0, reps: [])
    iseq = iseq.pack("C*") if iseq.is_a?(Array)
    rec = [0, 1, nregs, reps.size, 0, iseq.bytesize].pack("NnnnnN") + iseq
    rec << [plen].pack("n")
    rec << [1].pack("C") << [42].pack("N") if plen.positive? # IREP_TT_INT32 の pool を1つ
    rec << [syms.size].pack("n")
    syms.each { |s| rec << [s.bytesize].pack("n") << s << "\0" }
    reps.each { |c| rec << c }
    rec
  end
  
  def op(name)
    FpgaIsa.op(name).num
  end
end
