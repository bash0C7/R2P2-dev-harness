# PERIDOT-Air のボードエミュレーター (fpga/sim/board_emu_tb.sv) のログを読み、人が読む形にし、
# 参照インタプリタ (ref_vm.rb) と LED の変化の系列を突き合わせる。rake fpga:emu が使う。
#
# ログは1行 "<us> <what> <value>"。what は LED / LED2 / BUTTON / HALT / ERROR / END。
require_relative "converter"
require_relative "compare"

module FpgaEmu
  DEFAULT_MHZ = 125 # Raspberry Pi Pico と同じ
  CYCLES_PER_STEP = 2 # mrb_core は1命令 2 cycle (en の cycle で数えて)

  Event = Struct.new(:us, :what, :value)

  module_function

  def read_log(path)
    File.readlines(path, chomp: true).map do |l|
      us, what, value = l.split
      Event.new(us.to_i, what, value.to_i)
    end
  end

  # 回路の CE_DIV と、時刻の倍率。CE_DIV を小さくして速く回し、時刻を倍率だけ引き延ばす
  def scale(ce_div, fast: true)
    return [ce_div, 1] unless fast
    k = 1
    [100, 10].each do |f|
      if (ce_div % f).zero? && ce_div / f >= 10
        k = f
        break
      end
    end
    [ce_div / k, k]
  end

  def format_events(events)
    events.map do |e|
      t = format("%8.3f s", e.us / 1_000_000.0)
      case e.what
      when "LED", "LED2" then "#{t}  #{e.what.ljust(6)} #{e.value == 1 ? 'on' : 'off'}"
      when "BUTTON"      then "#{t}  button #{e.value == 1 ? 'pressed' : 'released'}"
      when "HALT"        then "#{t}  CPU halted at pc #{e.value}"
      when "ERROR"       then "#{t}  CPU error at pc #{e.value}"
      when "END"         then "#{t}  (end)"
      end
    end
  end

  # LED ごとの反転の間隔 (秒) の平均
  def periods(events)
    %w[LED LED2].to_h do |pin|
      ts = events.select { |e| e.what == pin }.map(&:us)
      gaps = ts.each_cons(2).map { |a, b| b - a }.drop(1) # 最初の区間はリセット直後からなので除く
      [pin, gaps.empty? ? nil : gaps.sum / gaps.size / 1_000_000.0]
    end
  end

  # ms の間に実行される命令の数 (リセット直後の数 cycle は無視できる)
  def window_steps(ms, ce_div, mhz = DEFAULT_MHZ)
    (ms / 1000.0 * mhz * 1_000_000 / (CYCLES_PER_STEP * ce_div)).floor
  end

  # 境界の前後の揺れ (リセット解除の同期、クロックイネーブルの位相) を吸収する余裕
  STEP_SLACK = 4

  # 参照インタプリタを何 step 回せば ms の間の命令を全部含むか
  def steps_for(ms, ce_div, mhz = DEFAULT_MHZ)
    window_steps(ms, ce_div, mhz) + STEP_SLACK
  end

  # 参照インタプリタの O 行から、ピンの点灯 (true / false) の変化の列を作る (最初は消灯)
  # upto: この step より後の書き込みは数えない
  def ref_pin_sequence(trace, port, upto: nil)
    seq = [false]
    trace.grep(/\AO /).each do |l|
      step = l.split[1].to_i
      next if upto && step > upto
      p, v = FpgaCompare.outputs([l]).first
      next unless p == port
      lit = v == true || (v.is_a?(Integer) && v != 0)
      seq << lit unless seq.last == lit
    end
    seq
  end

  def emu_pin_sequence(events, pin)
    events.select { |e| e.what == pin }.map { |e| e.value == 1 }
  end

  # エミュレーターの系列が、参照インタプリタを同じ時間だけ回した系列と一致するか。[ok, message]
  # 窓の端の揺れのぶん、参照は「窓 - STEP_SLACK」から「窓 + STEP_SLACK」 step の間のどこで切ってもよい
  def check_against_ref(events, trace, window)
    [["LED", 0], ["LED2", 1]].map do |pin, port|
      emu = emu_pin_sequence(events, pin)
      ref = ref_pin_sequence(trace, port, upto: window + STEP_SLACK)
      lo = ref_pin_sequence(trace, port, upto: window - STEP_SLACK)
      if ref[0, emu.size] == emu && emu.size >= lo.size
        [true, "#{pin}: #{emu.size - 1} change(s), same as the reference interpreter"]
      else
        [false, "#{pin}: emulator #{emu.inspect} vs reference #{ref[0, emu.size + 2].inspect}"]
      end
    end
  end
end
