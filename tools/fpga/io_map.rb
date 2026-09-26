# グローバル変数と I/O ポートの対応表。
#
# ROM 変換 (rom.rb) が GETGV / SETGV のシンボルをここのポート番号に置き換えるので、
# ハードウェアはシンボル表を持たない。シミュレーション (fpga/sim/mrb_run_tb.sv)、
# 参照インタプリタ (ref_vm.rb)、実機のピン割り当てはすべてこの番号で話す。
#
# out: SETGV で書く。GETGV で読むと最後に書いた値 (書く前は nil)。
# in:  GETGV で読むと外から入った値 (Integer)。SETGV は変換時にエラー。
module FpgaIoMap
  Port = Struct.new(:name, :num, :dir)

  PORTS = [
    Port.new("$LED",    0, :out),  # PERIDOT-Air USER_LED[0]
    Port.new("$LED2",   1, :out),  # PERIDOT-Air USER_LED[1]
    Port.new("$BUTTON", 2, :in)
  ].freeze

  BY_NAME = PORTS.to_h { |p| [p.name, p] }.freeze

  # ハードウェアの I/O ブロックのポート数と、入力ポートの bit mask
  NPORTS  = 4
  IN_MASK = PORTS.select { |p| p.dir == :in }.sum { |p| 1 << p.num }

  module_function

  def fetch(name)
    BY_NAME[name]
  end

  def port(num)
    PORTS.find { |p| p.num == num }
  end
end
