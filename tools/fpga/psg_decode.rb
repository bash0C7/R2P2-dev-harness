# PSG (FPGA の外の音源) の音を、コアが PSG の列から取り出したパケットから組み立てる (docs/spec.md §10「PSG (P5e)」)。
# 参照とシミュレーションのトレースの P 行 (P <step> <ms> <{op, reg, val, arg}> <aux>) とエミュレーターのログ (PSG / PSGAUX /
# PSGSEL) の両方から使う。レジスタとパケットの意味は PicoRuby の picoruby-psg の ports/common/psg.c (PSG_process_packet と
# PSG_write_reg) と同じ。出すのは声 (0..2) ごとの鳴っている音の変わり目: [時刻, 声, [音名, 周波数, 音量, 音色] か nil (止まった)]。
# 波形 (エンベロープ、LFO、ノイズ、パン) までは作らない
module FpgaPsg
  NAMES = %w[C C# D D# E F F# G G# A A# B].freeze
  TIMBRES = %w[square triangle sawtooth invsawtooth].freeze
  TONE_K = 2_000_000 / 32.0 # CHIP_CLOCK / 32
  SELECT = 0x1A5
  OP_REG = 0
  OP_MUTE = 2
  OP_TIMBRE = 4
  OP_VOICE = 6
  OP_DIRECT_REG = 0x80
  OP_DIRECT_MUTE = 0x81

  class Chip
    attr_reader :events

    def initialize
      @events = []
      reset
    end

    # C の reset_psg: 音量 15、トーンだけ、全部の声を mute
    def reset
      @tone = [0, 0, 0]
      @volume = [15, 15, 15]
      @mixer = 0x38
      @mute = 0x07
      @timbre = [0, 0, 0]
      @last = [nil, nil, nil]
    end

    def apply(t, word, aux)
      op = word >> 24
      reg = (word >> 16) & 0xFF
      val = (word >> 8) & 0xFF
      arg = word & 0xFF
      case op
      when OP_REG then write_reg(reg, val)
      when OP_DIRECT_REG then write_reg(reg, arg) # {0x80, reg, 0, val}
      when OP_MUTE then mute(reg & 3, val)
      when OP_DIRECT_MUTE then mute(reg & 3, arg)
      when OP_TIMBRE then @timbre[reg & 3] = val if (reg & 3) < 3
      when OP_VOICE then voice_write(reg & 3, val & 0x1F, (arg >> 6) & 3, aux & 0x0FFF)
      end
      emit(t)
    end

    def select(t)
      reset
      emit(t)
    end

    def write_reg(reg, val)
      case reg
      when 0, 2, 4 then @tone[reg / 2] = (@tone[reg / 2] & 0xF00) | val
      when 1, 3, 5 then @tone[reg / 2] = (@tone[reg / 2] & 0x0FF) | ((val & 0x0F) << 8)
      when 7 then @mixer = val & 0x3F
      when 8, 9, 10 then @volume[reg - 8] = val & 0x1F
      end
    end

    def mute(tr, flag)
      return if tr > 2
      flag.zero? ? @mute &= ~(1 << tr) : @mute |= (1 << tr)
    end

    def voice_write(tr, volume, flags, period)
      return if tr > 2
      if volume.zero?
        @volume[tr] = 0
        @mute |= 1 << tr
        return
      end
      @tone[tr] = period
      (flags & 1).zero? ? @mixer |= (1 << tr) : @mixer &= ~(1 << tr)
      (flags & 2).zero? ? @mixer |= (1 << (tr + 3)) : @mixer &= ~(1 << (tr + 3))
      @volume[tr] = volume
      @mute &= ~(1 << tr)
    end

    # 声 tr の鳴っている音 (鳴っていなければ nil)。音量 16 以上 (bit 4) はエンベロープ
    def voice(tr)
      return nil if @mute[tr] == 1 || @volume[tr].zero? || @mixer[tr] == 1 || @tone[tr].zero?
      f = TONE_K / @tone[tr]
      n = (12 * Math.log2(f / 440.0) + 69).round
      [format("%s%d", NAMES[n % 12], n / 12 - 1), f.round(1), (@volume[tr] & 0x10).zero? ? @volume[tr] : "env",
       TIMBRES[@timbre[tr]] || @timbre[tr].to_s]
    end

    def emit(t)
      3.times do |tr|
        v = voice(tr)
        next if v == @last[tr]
        @events << [t, tr, v]
        @last[tr] = v
      end
    end
  end

  module_function

  # トレース (参照かシミュレーション) から [ms, 声, 音] の列
  def from_trace(trace)
    chip = Chip.new
    trace.each do |l|
      if l.start_with?("P ")
        _, _, ms, word, aux = l.split
        chip.apply(ms.to_i, word.to_i(16), aux.to_i(16))
      elsif l.start_with?("O ") && l.split[2].to_i == SELECT
        chip.select(chip.events.empty? ? 0 : chip.events.last[0])
      end
    end
    chip.events
  end

  # 人が読む形。unit は時刻の単位 (トレースは ms、エミュレーターは µs)
  def format_events(events, unit: :ms)
    events.map do |t, tr, v|
      s = unit == :ms ? t / 1000.0 : t / 1_000_000.0
      what = v ? "#{v[0].ljust(4)} #{format('%7.1f', v[1])} Hz  vol #{v[2]}  #{v[3]}" : "off"
      format("%8.3f s  psg%d   %s", s, tr, what)
    end
  end
end
