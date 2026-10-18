# FPGA 版の psg の C の部分 (PicoRuby の picoruby-psg、src/mruby/psg.c と ports/common/psg.c)。docs/spec.md §10「PSG (P5e)」。
# 音を作る PSG は FPGA の外 (DAC / PWM の先) とみなし、回路 (mrb_dev) はパケットの列 (ring buffer、256 枠) だけを持つ:
#   0x1A0 次に積むパケットの遅延 (ms)、0x1A1 aux (16bit)、0x1A2 {op, reg, val, arg} を書くと積む (満杯なら捨てる)、
#   0x1A3 空きの数 (止めていれば 0)、0x1A4 空なら 1 (書くと flush)、0x1A5 選んだ出力 (0 止める、1 PWM、2 MCP4922。書くと
#   初めから)、0x1A6 {reg, val} を列を通さずに書く、0x1A7 {tr, flag} を列を通さずに mute
# 取り出しは仮想の時計の 1ms ごと (C の psg_process_packets)。取り出したパケットはトレースの P 行になり、音はデコーダーが組み立てる。
# Ruby で書いた部分 (Driver#join など、Synth、Sound、MIDIController) は PicoRuby の mrblib をそのまま使う
module PSG
  DRUM_CHANNEL = 9
  PSG_DELAY = 0x1A0
  PSG_AUX = 0x1A1
  PSG_PUSH = 0x1A2
  PSG_FREE = 0x1A3
  PSG_EMPTY = 0x1A4
  PSG_SELECT = 0x1A5
  PSG_DIRECT_REG = 0x1A6
  PSG_DIRECT_MUTE = 0x1A7
  TONE_K = 2_000_000 / 32.0 # CHIP_CLOCK / 32
  JUST_MAJOR_NUM = [1, 16, 9, 6, 5, 4, 45, 3, 8, 5, 9, 15]
  JUST_MAJOR_DEN = [1, 15, 8, 5, 4, 3, 32, 2, 5, 3, 5, 8]
  JUST_MINOR_NUM = [1, 16, 10, 6, 5, 4, 64, 3, 8, 5, 9, 15]
  JUST_MINOR_DEN = [1, 15, 9, 5, 4, 3, 45, 2, 5, 3, 5, 8]
  JUST_TONICS = { c: 0, c_sharp: 1, d_flat: 1, d: 2, d_sharp: 3, e_flat: 3, e: 4, f: 5, f_sharp: 6, g_flat: 6, g: 7,
                  g_sharp: 8, a_flat: 8, a: 9, a_sharp: 10, b_flat: 10, b: 11 }
  # 音程の表 (period × 256) と A4 の周波数。最初に使う時に平均律で作る (C は gem を読んだ時)
  TUNING = [nil, 440.0]

  def self.__equal_frequency(note, a4)
    a4 * 2.0**((note - 69.0) / 12.0)
  end

  def self.__period_q8(frequency)
    ((TONE_K / frequency) * 256.0 + 0.5).to_i
  end

  def self.__table
    set_tuning if TUNING[0].nil?
    TUNING[0]
  end

  def self.set_tuning(tuning = :equal, pitch: 440)
    a4 = pitch.to_f
    raise ArgumentError, "Invalid PSG tuning pitch: #{a4}" if a4 <= 0.0
    table = []
    if tuning == :equal
      128.times { |n| table << __period_q8(__equal_frequency(n.to_f, a4)) }
    else
      name = tuning.to_s
      minor = name.end_with?("_minor")
      key = name.start_with?("just_") && name.size > 11 ? name[5, name.size - 11] : nil # just_<key>_major / _minor
      tonic = key && JUST_TONICS[key.to_sym]
      raise ArgumentError, "Unsupported PSG tuning: #{tuning}" unless tonic && (minor || name.end_with?("_major"))
      num = minor ? JUST_MINOR_NUM : JUST_MAJOR_NUM
      den = minor ? JUST_MINOR_DEN : JUST_MAJOR_DEN
      tonic_note = 60 + tonic
      tonic_frequency = __equal_frequency(tonic_note.to_f, a4)
      128.times do |n|
        diff = n - tonic_note
        degree = diff % 12
        octave = (diff - degree) / 12
        table << __period_q8(tonic_frequency * num[degree] / den[degree] * 2.0**octave)
      end
    end
    TUNING[0] = table
    TUNING[1] = a4
    tuning
  end

  def self.note_to_period(note, round: true)
    note = note.to_f
    if 0.0 <= note && note <= 127.0
      table = __table
      index = note.to_i
      q8 = table[index]
      q8 += ((table[index + 1] - q8) * (note - index)).to_i if note != index && index < 127
      return round ? (q8 + 128) >> 8 : q8 >> 8
    end
    period = TONE_K / __equal_frequency(note, TUNING[1])
    period += 0.5 if round
    period.to_i
  end

  class Driver
    CHIP_CLOCK = 2_000_000
    SAMPLE_RATE = 22_050
    TIMBRES = { square: 0, triangle: 1, sawtooth: 2, invsawtooth: 3 }

    def self.select_pwm(left, right)
      __io_write(PSG_SELECT, 1)
      nil
    end

    def self.select_mcp4922(ldac)
      __io_write(PSG_SELECT, 2)
      nil
    end

    # パケットを積む (C の PSG_rb_push)。満杯か止めていれば false
    def __psg_push(op, reg, val, arg, aux, delay)
      return false if __io_read(PSG_FREE) == 0
      __io_write(PSG_DELAY, delay)
      __io_write(PSG_AUX, aux & 0xFFFF)
      __io_write(PSG_PUSH, ((op & 0xFF) << 24) | ((reg & 0xFF) << 16) | ((val & 0xFF) << 8) | (arg & 0xFF))
      true
    end

    def send_reg(reg, val, tick_delay = 0)
      __psg_push(0, reg, val, 0, 0, tick_delay)
    end

    def voice_write(voice, tone_period, noise_period, volume, mixer_flags)
      if voice < 0 || 2 < voice || tone_period < 0 || 0x0FFF < tone_period || noise_period < 0 || 31 < noise_period ||
         volume < 0 || 31 < volume || mixer_flags < 0 || 3 < mixer_flags
        raise ArgumentError, "Invalid PSG voice write"
      end
      __psg_push(6, voice, volume, ((mixer_flags & 3) << 6) | (noise_period & 0x1F), tone_period, 0)
    end

    def buffer_empty?
      __io_read(PSG_EMPTY) == 1
    end

    def buffer_flush
      __io_write(PSG_EMPTY, 1)
      nil
    end

    def deinit
      __io_write(PSG_SELECT, 0)
      nil
    end

    def set_lfo(tr, depth, rate, tick_delay = 0)
      __psg_push(1, tr, depth, rate, 0, tick_delay)
    end

    def set_pan(tr, pan, tick_delay = 0)
      raise ArgumentError, "Invalid track or pan value: #{tr}, #{pan}" if tr < 0 || tr > 2 || pan < 0 || pan > 15
      __psg_push(3, tr, pan, 0, 0, tick_delay)
    end

    def set_timbre(tr, timbre, tick_delay = 0)
      raise ArgumentError, "Invalid track: #{tr} (0-2 expected)" if tr < 0 || 2 < tr
      __psg_push(4, tr, timbre, 0, 0, tick_delay)
    end

    def set_legato(tr, legato, tick_delay = 0)
      raise ArgumentError, "Invalid track: #{tr} (0-2 expected)" if tr < 0 || 2 < tr
      __psg_push(5, tr, legato, 0, 0, tick_delay)
    end

    def mute(tr, flag, tick_delay = 0)
      __psg_push(2, tr, flag, 0, 0, tick_delay)
    end

    def write_reg_direct(reg, val)
      __io_write(PSG_DIRECT_REG, ((reg & 0xFF) << 8) | (val & 0xFF))
      nil
    end

    def mute_direct(tr, flag)
      __io_write(PSG_DIRECT_MUTE, ((tr & 0xFF) << 8) | (flag & 0xFF))
      nil
    end
  end
end
