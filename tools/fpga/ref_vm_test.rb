require_relative "test_helper"
require_relative "converter"
require_relative "ref_vm"
require_relative "compare"
require_relative "oracle"
require_relative "psg_decode"

class FpgaRefVmTest < Minitest::Test
  include FpgaTestHelper

  def run_words(words, max: 1000, stim: [])
    vm = FpgaRefVm.new(words, stim: stim)
    [vm, vm.run(max)]
  end

  def w(name, a = 0, b = 0, c = 0)
    FpgaRom::Word.new(0, nil, op(name), a, b, c).value
  end

  # Integer は 64bit (P8): LOADI32 は符号拡張、2**31 はあふれない。64bit からあふれると (例外の表が無ければ) エラー停止
  def test_int_is_64_bits
    vm, trace = run_words([w("LOADI32", 1, 0x7FFF, 0xFFFF), w("ADDI", 1, 1), w("LOADI32", 2, 0xFFFF, 0xFFFE), w("STOP")])
    assert_equal [FpgaIsa::TAG_INT, 0x8000_0000], vm.regs[1]
    assert_equal [FpgaIsa::TAG_INT, 2**64 - 2], vm.regs[2] # -2
    assert_equal "W 1 1 3 0000000080000000", trace[3]
    assert_equal "H 3 3", trace.last
    vm, trace = run_words([w("LOADI32", 1, 0x4000, 0), w("MOVE", 2, 1), w("MUL", 1), w("MOVE", 2, 1), w("MUL", 1), w("STOP")])
    assert_equal [FpgaIsa::TAG_INT, 2**60], vm.regs[1] # 2**120 はあふれる
    assert_equal format("E 4 4 %02x", op("MUL")), trace.last
  end

  def test_arith_on_nil_is_an_error
    _vm, trace = run_words([w("LOADI_1", 1), w("LOADNIL", 2), w("ADD", 1), w("STOP")])
    assert_equal format("E 2 2 %02x", op("ADD")), trace.last
  end

  def test_running_off_the_end_is_an_error
    _vm, trace = run_words([w("NOP")])
    assert_equal "E 1 1 ff", trace.last
  end

  def test_step_limit
    _vm, trace = run_words([w("JMP", 0, 0)], max: 5)
    assert_equal "L 5", trace.last
  end

  def test_input_follows_stimulus_by_step
    # 0: GETGV R1 $BUTTON, 1: JMP 0
    _vm, trace = run_words([w("GETGV", 1, 2), w("JMP", 0, 0)], max: 8, stim: [[4, 2, 1]])
    reads = trace.grep(/\AW /).map { |l| l.split.last.to_i(16) }
    assert_equal [0, 0, 1, 1], reads # step 0, 2, 4, 6
  end

  # 参照インタプリタ自体の正しさ: CRuby で同じ .rb を走らせ、ピンへの代入の系列を比べる。止まるプログラムは
  # console に書いたバイト列も CRuby の標準出力と比べる。入力を読むプログラム (.stim があるもの) は step と対応が付かないので対象外。
  # watchdog の再起動、Task (区画の切り替え)、PSG の列 (仮想の時計で進む)、64bit の桁あふれ (CRuby は Bignum に上がる) は
  # CRuby では表せないので比べない (Task と int64 は下で picoruby と比べる)
  # picotest は PicoRuby の gem を使い、caller は CRuby と表し方 ("in 'Walker#inner'") が違うので、picoruby と比べる
  CRUBY_CANNOT = %w[watchdog tasks psg mml int64 picotest caller].freeze

  def test_corpus_agrees_with_cruby
    Dir[File.join(CORPUS, "*.rb")].sort.each do |src|
      name = File.basename(src, ".rb")
      next if File.file?(File.join(CORPUS, "#{name}.stim")) || CRUBY_CANNOT.include?(name)
      words = FpgaConverter.read_hex(File.join(CORPUS, "#{name}.hex"))
      trace = FpgaRefVm.new(words).run(200_000)
      ours = FpgaCompare.outputs(trace)
      console = FpgaCompare.console(trace)
      refute(ours.empty? && console.empty?, name)
      halted = trace.last.start_with?("H ")
      cruby, stdout = FpgaOracle.cruby_run(src, limit: halted ? 1_000_000 : ours.size)
      assert_equal cruby, ours, name
      assert_equal stdout, console, name if halted
    end
  end

  # picoruby の組み込みに無いメソッド (Hash#min_by、sort_by、Array#tally、zip、each_slice、Range#sum ...) を使うので、
  # picoruby とは比べないもの (CRuby とは比べる)。errors はメッセージが PicoRuby と違うもの (Integer()、キーワード引数) を出す
  PICORUBY_LACKS = %w[collections errors].freeze # FPGA 版の gem を使うもの (devices など) も比べない (test の中で除く)

  # 止まるプログラムは、picoruby host VM (本物の mruby VM) の最後の値とも比べる
  def test_finite_corpus_agrees_with_picoruby
    skip "picoruby is not built (rake fpga:picoruby)" unless File.executable?(PICORUBY)
    checked = 0
    Dir[File.join(CORPUS, "*.rb")].sort.each do |src|
      name = File.basename(src, ".rb")
      next if PICORUBY_LACKS.include?(name) || !FpgaCorpus.gem_files(src).empty?
      words = FpgaConverter.read_hex(File.join(CORPUS, "#{name}.hex"))
      vm = FpgaRefVm.new(words)
      trace = vm.run(200_000)
      next unless trace.last.start_with?("H ")
      ours = FpgaIoMap.pins_out.to_h { |p| [p.num, FpgaCompare.decode(*vm.io[p.num])] }
      final, stdout = FpgaOracle.picoruby_run(src, picoruby: PICORUBY)
      assert_equal final, ours, name
      assert_equal stdout, FpgaCompare.console(trace), name
      checked += 1
    end
    assert_operator checked, :>=, 2
  end

  # Task を使うプログラム (区画の切り替えと tick) は、picoruby host VM (mruby-task) の標準出力と比べる。
  # host の tick は 4ms、FPGA は 1ms なので、出力の順が tick の単位に依らない書き方のものだけ置く (tasks.rb)
  TASK_PROGRAMS = %w[tasks].freeze

  def test_task_corpus_agrees_with_picoruby
    skip "picoruby is not built (rake fpga:picoruby)" unless File.executable?(PICORUBY)
    TASK_PROGRAMS.each do |name|
      src = File.join(CORPUS, "#{name}.rb")
      trace = FpgaRefVm.new(FpgaConverter.read_hex(File.join(CORPUS, "#{name}.hex"))).run(400_000)
      assert trace.last.start_with?("H "), "#{name}: #{trace.last}"
      _final, stdout = FpgaOracle.picoruby_run(src, picoruby: PICORUBY)
      assert_equal stdout, FpgaCompare.console(trace), name
    end
  end

  # picotest (P9): Picotest::Runner が板に渡すのと同じ形のスクリプト。picoruby host VM (picotest の gem 入り) の標準出力
  # (テストごとの . F E S と、失敗の中身の JSON) と全部比べる
  def test_picotest_corpus_agrees_with_picoruby
    skip "picoruby is not built (rake fpga:picoruby)" unless File.executable?(PICORUBY)
    src = File.join(CORPUS, "picotest.rb")
    trace = FpgaRefVm.new(FpgaConverter.read_hex(File.join(CORPUS, "picotest.hex"))).run(2_000_000)
    assert trace.last.start_with?("H "), trace.last
    _final, stdout = FpgaOracle.picoruby_run(src, picoruby: PICORUBY)
    assert_equal stdout, FpgaCompare.console(trace)
  end

  # プレリュードの RUBY_ENGINE などは host の PicoRuby と同じ値 (vendor/picoruby の version.h)
  def test_prelude_versions_match_picoruby
    skip "vendor/picoruby is not there" unless File.directory?(VENDOR)
    core = File.read(File.join(ROOT, "fpga", "prelude", "core.rb"), encoding: "UTF-8")
    mruby_h = File.read(File.join(VENDOR, "mrbgems", "picoruby-mruby", "lib", "mruby", "include", "mruby", "version.h"))
    pico_h = File.read(File.join(VENDOR, "include", "version.h"))
    mv = %w[MAJOR MINOR TEENY].map { |k| mruby_h[/#define MRUBY_RELEASE_#{k}\s+(\d+)/, 1] }.join(".")
    assert_includes core, %(RUBY_ENGINE = "#{mruby_h[/#define MRUBY_RUBY_ENGINE\s+"(.+?)"/, 1]}")
    assert_includes core, %(RUBY_VERSION = "#{mruby_h[/#define MRUBY_RUBY_VERSION\s+"(.+?)"/, 1]}")
    assert_includes core, %(MRUBY_VERSION = "#{mv}")
    assert_includes core, %(PICORUBY_VERSION = "#{pico_h[/#define PICORUBY_VERSION\s+"(.+?)"/, 1]}")
  end

  # PSG (P5e): 音程は C の psg_period_q8 と同じ式 (CHIP_CLOCK / 32 / 周波数 × 256 を丸める) で CRuby が計算した値、
  # 音はトレースの P 行を psg_decode.rb で組み立てた並び (250ms ごとに C4 E4 G4 C5)
  def test_psg_corpus_matches_the_c_formulas
    k = 2_000_000 / 32.0
    q8 = ->(f) { ((k / f) * 256 + 0.5).to_i }
    eq = ->(n, a4 = 440.0) { a4 * 2**((n - 69) / 12.0) }
    period = ->(q) { (q + 128) >> 8 }
    half = q8.(eq.(60)) + ((q8.(eq.(61)) - q8.(eq.(60))) * 0.5).to_i
    expected = [period.(q8.(eq.(60))), q8.(eq.(60)) >> 8, period.(q8.(eq.(69))), period.(half), (k / eq.(130) + 0.5).to_i,
                period.(q8.(eq.(60) * 5 / 4)), period.(q8.(eq.(69, 442.0)))]
    assert_equal [239, 238], expected[0, 2] # picoruby-psg の README
    trace = FpgaRefVm.new(FpgaConverter.read_hex(File.join(CORPUS, "psg.hex"))).run(400_000)
    assert trace.last.start_with?("H "), trace.last
    assert_equal expected.map(&:to_s), FpgaCompare.console(trace).lines.first(7).map(&:strip)
    notes = FpgaPsg.from_trace(trace).select { |_, v, n| v.zero? && n }.map { |t, _, n| [t, n[0]] }
    assert_equal %w[C4 E4 G4 C5], notes.map(&:last)
    assert_equal [250, 250, 250], notes.each_cons(2).map { |(a, _), (b, _)| b - a }
  end

  # MML (P8): midibase-mml の Player の待ち時間 (delta_ticks * 60_000_000 / (ppqn * tempo)) は 64bit の Integer で計算する。
  # T120 の四分音符は 500ms (Task の tick の 1ms ずれは PicoRuby の sleep と同じ)。32bit では桁があふれて数 ms に詰まった
  def test_mml_corpus_waits_a_quarter_note_between_notes
    trace = FpgaRefVm.new(FpgaConverter.read_hex(File.join(CORPUS, "mml.hex"))).run(1_000_000)
    assert trace.last.start_with?("H "), trace.last
    assert_equal "end\n", FpgaCompare.console(trace)
    notes = FpgaPsg.from_trace(trace).select { |_, v, n| v.zero? && n }.map { |t, _, n| [t, n[0]] }
    assert_equal %w[F5 F5 C6 C6], notes.map(&:last)
    notes.each_cons(2) { |(a, _), (b, _)| assert_includes 500..501, b - a }
  end
end
