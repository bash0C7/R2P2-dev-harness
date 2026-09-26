require_relative "test_helper"
require_relative "converter"
require_relative "ref_vm"
require_relative "compare"
require_relative "oracle"

class FpgaRefVmTest < Minitest::Test
  include FpgaTestHelper

  def run_words(words, max: 1000, stim: [])
    vm = FpgaRefVm.new(words, stim: stim)
    [vm, vm.run(max)]
  end

  def w(name, a = 0, b = 0, c = 0)
    FpgaRom::Word.new(0, nil, op(name), a, b, c).value
  end

  def test_int_wraps_at_32_bits
    vm, trace = run_words([w("LOADI32", 1, 0x7FFF, 0xFFFF), w("ADDI", 1, 1), w("STOP")])
    assert_equal [FpgaIsa::TAG_INT, 0x8000_0000], vm.regs[1]
    assert_equal "H 2 2", trace.last
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
  def test_corpus_agrees_with_cruby
    Dir[File.join(CORPUS, "*.rb")].sort.each do |src|
      name = File.basename(src, ".rb")
      next if File.file?(File.join(CORPUS, "#{name}.stim"))
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
  PICORUBY_LACKS = %w[collections errors].freeze

  # 止まるプログラムは、picoruby host VM (本物の mruby VM) の最後の値とも比べる
  def test_finite_corpus_agrees_with_picoruby
    skip "vendor/picoruby/bin/picoruby is not built" unless File.executable?(PICORUBY)
    checked = 0
    Dir[File.join(CORPUS, "*.rb")].sort.each do |src|
      name = File.basename(src, ".rb")
      next if PICORUBY_LACKS.include?(name)
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
end
