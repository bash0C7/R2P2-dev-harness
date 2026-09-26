# グローバル変数と I/O ポートの対応表。
#
# ROM 変換 (rom.rb) が GETGV / SETGV のシンボルをここのポート番号に置き換えるので、
# ハードウェアはシンボル表を持たない。シミュレーション (fpga/sim/mrb_run_tb.sv)、
# 参照インタプリタ (ref_vm.rb)、実機のピン割り当てはすべてこの番号で話す。
#
# out: SETGV で書く。GETGV で読むと最後に書いた値 (書く前は nil)。
# in:  GETGV で読むと外から入った値 (Integer)。SETGV は変換時にエラー。
#
# 変換器の一部として PicoRuby でも走る (isa.rb の注記)。
module FpgaIoMap
  class Port
    attr_reader :name, :num, :dir

    def initialize(name, num, dir)
      @name = name
      @num = num
      @dir = dir
    end
  end

  PORTS = [
    Port.new("$LED",    0, :out),  # PERIDOT-Air USER_LED[0]
    Port.new("$LED2",   1, :out),  # PERIDOT-Air USER_LED[1]
    Port.new("$BUTTON", 2, :in)    # PERIDOT-Air D[0]
  ].freeze

  BY_NAME = {}
  PORTS.each { |p| BY_NAME[p.name] = p }
  BY_NAME.freeze

  # ハードウェアの I/O ブロックのポート数と、入力ポートの bit mask
  NPORTS = 4
  mask = 0
  PORTS.each { |p| mask |= (1 << p.num) if p.dir == :in }
  IN_MASK = mask

  def self.fetch(name)
    BY_NAME[name]
  end

  def self.port(num)
    PORTS.find { |p| p.num == num }
  end
end
