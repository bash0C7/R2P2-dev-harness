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
  def rite(iseq, nregs: 4, syms: [], pool: [], reps: [])
    rec = irep_record(iseq, nregs: nregs, syms: syms, pool: pool, reps: reps)
    irep = "IREP" + [12 + rec.bytesize].pack("N") + "0400" + rec
    body = irep + "END\0" + [8].pack("N")
    "RITE0400" + [20 + body.bytesize].pack("N") + "MATZ0000" + body
  end
  
  # pool: String は IREP_TT_STR、Integer は IREP_TT_INT32 (64bit に収まらなければ INT64)、:float は IREP_TT_FLOAT
  def irep_record(iseq, nregs: 4, syms: [], pool: [], reps: [])
    iseq = iseq.pack("C*") if iseq.is_a?(Array)
    rec = [0, 1, nregs, reps.size, 0, iseq.bytesize].pack("NnnnnN") + iseq
    rec << [pool.size].pack("n")
    pool.each do |e|
      case e
      when String then rec << [0, e.bytesize].pack("Cn") << e << "\0"
      when :float then rec << [5].pack("C") << ("\0" * 8)
      else
        rec << (e.between?(-2**31, 2**31 - 1) ? [1, e & 0xFFFF_FFFF].pack("CN") : [3, (e >> 32) & 0xFFFF_FFFF, e & 0xFFFF_FFFF].pack("CNN"))
      end
    end
    rec << [syms.size].pack("n")
    syms.each { |s| rec << [s.bytesize].pack("n") << s << "\0" }
    reps.each { |c| rec << c }
    rec
  end
  
  def op(name)
    FpgaIsa.op(name).num
  end
end
