require_relative "test_helper"
require_relative "converter"
require "tmpdir"

class FpgaRomTest < Minitest::Test
  include FpgaTestHelper

  # fpga/corpus/<name>.dump (mrbc -v の命令行) と、変換結果を1命令ずつ突き合わせる
  def test_corpus_matches_mrbc_dump
    names = Dir[File.join(CORPUS, "*.mrb")].map { |p| File.basename(p, ".mrb") }.sort
    refute_empty names
    names.each do |name|
      image = FpgaRom.from_binary(File.binread(File.join(CORPUS, "#{name}.mrb")))
      dump = File.readlines(File.join(CORPUS, "#{name}.dump"), chomp: true).map { |l| l.split(/\s+/, 4) }
      # 元の命令ごとの先頭の語 (iterator は数語に展開される)。dump の irep の順は ROM の並びと同じ
      firsts = image.words.select(&:first)
      pc_of = firsts.to_h { |w| [[w.irep.index, w.insn.addr], w.pc] }
      assert_equal dump.size, firsts.size, name
      dump.zip(firsts).each do |(_line, addr, opname, rest), w|
        where = "#{name} irep #{w.irep.index} byte #{addr}"
        assert_equal addr.to_i, w.insn.addr, where
        # mrbc -v は ARRAY2 も "ARRAY" と表示する
        assert_equal opname, w.insn.name == "ARRAY2" ? "ARRAY" : w.insn.name, where
        unless FpgaIsa::LOWERED.include?(opname)
          got = FpgaIsa::OPS[w.op].name
          assert_includes [w.insn.name, *REWRITTEN[w.insn.name]], got, where
        end
        fields = rest.to_s.split(/[\t ]+/).reject { |f| f.start_with?(";") }
        check_operands(where, opname, fields, w, pc_of)
      end
    end
  end

  # 別の命令に置き換わるもの: ブロックの ENTER は NOP、sleep_ms / sleep は SEND、block_given? は BLKPUSH、.call は BLKCALL
  REWRITTEN = { "ENTER" => %w[NOP], "SSEND" => %w[SEND], "SSEND0" => %w[SEND0 SEND BLKPUSH], "SEND" => %w[BLKCALL],
                "SEND0" => %w[BLKCALL] }.freeze

  def check_operands(where, opname, fields, w, pc_of)
    return if FpgaIsa::OPS[w.op].name != w.insn.name # 置き換えたものの中身は fpga:check と ref_vm_test が見る

    case opname
    when "JMP"
      assert_equal pc_of.fetch([w.irep.index, fields[0].to_i]), w.b, where
    when "JMPIF", "JMPNOT", "JMPNIL"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal pc_of.fetch([w.irep.index, fields[1].to_i]), w.b, where
    when "GETGV"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal FpgaIoMap.fetch(fields[1]).num, w.b, where
    when "SETGV"
      assert_equal FpgaIoMap.fetch(fields[0]).num, w.b, where
      assert_equal "R#{w.a}", fields[1], where
    when "MOVE"
      assert_equal ["R#{w.a}", "R#{w.b}"], fields[0, 2], where
    when "LOADI8", "LOADI16", "LOADI32", "LOADINEG"
      assert_equal "R#{w.a}", fields[0], where
      value = { "LOADI8" => w.b, "LOADI16" => (w.b >= 0x8000 ? w.b - 0x10000 : w.b),
                "LOADI32" => (w.b << 16) | w.c, "LOADINEG" => -w.b }.fetch(opname)
      assert_equal value, fields[1].to_i, where
    when "ADDI", "SUBI"
      assert_equal ["R#{w.a}", w.b.to_s], fields[0, 2], where
    when "ADDILV", "SUBILV"
      assert_equal ["R#{w.a}", "R#{w.b}", w.c.to_s], fields[0, 3], where
    when "NOP", "RETNIL", "STOP"
      assert_equal 0, w.a, where
    when "SENDB", "SSENDB", "BLOCK"
      nil # 下げた命令 (展開の中身は fpga:check と ref_vm_test が見る)
    when "BREAK"
      assert_equal "R#{w.a}", fields[0], where
    when "ENTER"
      assert_equal fields[0].split(":").first.to_i, w.a, where # 必須の引数の数
    when "TDEF"
      assert_equal ["R#{w.a}", 0, 0], ["R#{w.a}", w.b, w.c], where
    when "SSEND", "SSEND0"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal (opname == "SSEND" ? fields[2].delete("n=").to_i : 0), w.c & 0xFF, where
    when "SEND", "SEND0"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal fields[1].delete(":"), FpgaIsa::BUILTINS[w.b][0], where
    when "GETCONST"
      assert_equal "R#{w.a}", fields[0], where
    when "SETCONST"
      assert_equal "R#{w.a}", fields[1], where
    else
      assert_equal "R#{w.a}", fields[0], where
    end
  end

  def test_words_are_48_bits
    image = FpgaRom.from_binary(rite([op("LOADI32"), 1, 0x12, 0x34, 0x56, 0x78, op("STOP")]))
    assert_equal "0f0112345678", image.words[0].hex
    assert_equal "760000000000", image.words[1].hex
  end

  def test_jump_becomes_absolute_word_address
    # 0: JMP +1 (byte 3 -> byte 4), 3: NOP, 4: STOP
    image = FpgaRom.from_binary(rite([op("JMP"), 0x00, 0x01, op("NOP"), op("STOP")]))
    assert_equal 2, image.words[0].b
    # 後ろ向き: 0: NOP, 1: JMP -4 (byte 4 -> byte 0)
    image = FpgaRom.from_binary(rite([op("NOP"), op("JMP"), 0xFF, 0xFC]))
    assert_equal 0, image.words[1].b
  end

  def test_gvar_becomes_port
    image = FpgaRom.from_binary(rite([op("GETGV"), 1, 0, op("SETGV"), 1, 1, op("STOP")], syms: ["$BUTTON", "$LED2"]))
    assert_equal 2, image.words[0].b
    assert_equal 1, image.words[1].b
  end

  def test_rejects_unsupported_instruction_with_location
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("NOP"), op("ARYCAT"), 1, op("STOP")])) }
    assert_match(/unsupported instruction\(s\): ARYCAT at byte 001/, e.message)
  end

  def test_rejects_unknown_methods
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("SEND0"), 1, 0, op("STOP")], syms: ["puts"])) }
    assert_match(/\.puts with 0 argument\(s\) at byte 000 is not a supported method/, e.message)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("SSEND0"), 1, 0, op("STOP")], syms: ["foo"])) }
    assert_match(/foo at byte 000 is not a method defined with def/, e.message)
  end

  # def two; 2; end; two  →  子 irep は親の後ろに並び、SSEND0 の b はその先頭 pc、c は (nregs << 8) | 引数の数
  def test_methods_are_laid_out_after_the_caller_and_resolved
    child = irep_record([op("ENTER"), 0, 0, 0, op("LOADI_2"), 2, op("RETURN"), 2], nregs: 3)
    bin = rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("STOP")], syms: ["two"], reps: [child])
    image = FpgaRom.from_binary(bin)
    assert_equal %w[TDEF SSEND0 STOP ENTER LOADI_2 RETURN], image.words.map { |w| w.insn.name }
    assert_equal 3, image.words[1].b
    assert_equal (3 << 8) | 0, image.words[1].c
    assert_equal [0, 3], image.ireps.map(&:base)
    assert_match(/# irep 1  nregs 3\n   3  000  ENTER/, image.listing)
  end

  def test_rejects_optional_parameters_and_redefinition
    opt = irep_record([op("ENTER"), 0x04, 0x20, 0x00, op("RETNIL")]) # 1:1:... (optional 1)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("TDEF"), 1, 0, 0, op("STOP")], syms: ["f"], reps: [opt])) }
    assert_match(/only required parameters and &block are supported/, e.message)
    plain = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")])
    bin = rite([op("TDEF"), 1, 0, 0, op("TDEF"), 1, 0, 1, op("STOP")], syms: ["f"], reps: [plain, plain])
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(bin) }
    assert_match(/f is defined twice/, e.message)
  end

def test_blocks_are_lowered_only_for_the_known_iterators
    blk = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")], nregs: 3)
    # 3.select { } は受け付けない (ブロックを渡せるのは def したメソッドと決まった iterator だけ)
    bin = rite([op("LOADI_3"), 1, op("BLOCK"), 2, 0, op("SENDB"), 1, 0, 0, op("STOP")], syms: ["select"], reps: [blk])
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(bin) }
    assert_match(/select with a block at byte 005 is not supported/, e.message)
    # 3.times { } は展開される: BLOCK で Proc を作り、カウンタのループで BLKCALL する。
    # ループを抜けたら式の値 (受け手) のまま次へ、break の出口 (pc 13) はブロックのフレームの R0 を結果へ
    bin = rite([op("LOADI_3"), 1, op("BLOCK"), 2, 0, op("SENDB"), 1, 0, 0, op("STOP")], syms: ["times"], reps: [blk])
    words = FpgaRom.from_binary(bin).words
    assert_equal %w[LOADI_3 BLOCK LOADI_0 MOVE MOVE LT JMPNOT MOVE MOVE BLKCALL ADDI JMP JMP MOVE STOP NOP RETNIL],
                 words.map { |w| FpgaIsa::OPS[w.op].name }
    assert_equal [15, 3 << 8], [words[1].b, words[1].c] # 先頭 pc と (nregs << 8) | 引数の数
    assert_equal [4, 1], [words[9].a, words[9].b]
    assert_equal [1, 4], [words[13].a, words[13].b]
    # 渡さずに値にした BLOCK (proc や &blk) はそのまま Proc になる
    words = FpgaRom.from_binary(rite([op("BLOCK"), 1, 0, op("STOP")], reps: [blk])).words
    assert_equal %w[BLOCK STOP NOP RETNIL], words.map { |w| FpgaIsa::OPS[w.op].name }
  end

  # ブロックの外の変数は GETUPVAR c = 深さ + 1 で読む。深さを超える参照と、ブロックの外の break / return は止める
  def test_break_and_upvar_need_an_enclosing_block
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("BREAK"), 1, op("STOP")])) }
    assert_match(/break at byte 000 is not inside a block/, e.message)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("GETUPVAR"), 1, 1, 0, op("STOP")])) }
    assert_match(/GETUPVAR at byte 000 reaches 1 levels out, the block is 0 deep/, e.message)
    blk = irep_record([op("ENTER"), 0, 0, 0, op("GETUPVAR"), 1, 1, 0, op("RETURN"), 1], nregs: 3)
    words = FpgaRom.from_binary(rite([op("BLOCK"), 1, 0, op("STOP")], reps: [blk])).words
    assert_equal ["GETUPVAR", 1, 1, 1], [FpgaIsa::OPS[words[3].op].name, words[3].a, words[3].b, words[3].c]
    top_return = irep_record([op("ENTER"), 0, 0, 0, op("RETURN_BLK"), 1], nregs: 3)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("BLOCK"), 1, 0, op("STOP")], reps: [top_return])) }
    assert_match(/return inside a block at irep 1 byte 004 is not inside a method/, e.message)
  end

  # sleep_ms / sleep は self への呼び出しでも組み込み (SEND) にする。.call は BLKCALL
  def test_sleep_and_call_become_builtins
    bin = rite([op("LOADI_1"), 2, op("SSEND"), 1, 0, 1, op("MOVE"), 2, 1, op("SEND"), 2, 1, 0, op("STOP")],
               syms: %w[sleep_ms call])
    words = FpgaRom.from_binary(bin).words
    assert_equal %w[LOADI_1 SEND MOVE BLKCALL STOP], words.map { |w| FpgaIsa::OPS[w.op].name }
    assert_equal [1, FpgaIsa.builtin("sleep_ms", 1), 1], [words[1].a, words[1].b, words[1].c]
    assert_equal [2, 0], [words[3].a, words[3].b]
  end

  def test_rejects_pool
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("STOP")], plen: 1)) }
    assert_match(/pool/, e.message)
  end

  def test_rejects_unknown_gvar
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("GETGV"), 1, 0, op("STOP")], syms: ["$FOO"])) }
    assert_match(/\$FOO.*io_map/, e.message)
  end

  def test_rejects_write_to_input
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("SETGV"), 1, 0, op("STOP")], syms: ["$BUTTON"])) }
    assert_match(/input port/, e.message)
  end

  def test_rejects_too_many_registers
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("STOP")], nregs: 17), "(mrb)", 16) }
    assert_match(/needs 17 registers/, e.message)
  end

  # commit 済みの .hex / .lst は PicoRuby で走らせた変換器の出力。同じ file を CRuby で読んでも同じになること
  def test_committed_rom_matches_the_converter_on_cruby
    Dir[File.join(CORPUS, "*.mrb")].sort.each do |mrb|
      image = FpgaRom.from_binary(File.binread(mrb), mrb, 16)
      assert_equal File.read(mrb.sub(/\.mrb\z/, ".hex")), image.hex, mrb
      assert_equal File.read(mrb.sub(/\.mrb\z/, ".lst")), image.listing, mrb
    end
  end

  def with_picoruby
    skip "vendor/picoruby/bin/picoruby is not built" unless File.executable?(PICORUBY)
    Dir.mktmpdir { |dir| yield dir }
  end

  def picoruby_convert(dir, bin, max_regs: nil)
    mrb = File.join(dir, "in.mrb")
    File.binwrite(mrb, bin)
    FpgaConverter.run(mrb, File.join(dir, "out.hex"), File.join(dir, "out.lst"), max_regs: max_regs, picoruby: PICORUBY)
    File.read(File.join(dir, "out.hex"))
  end

  # 48bit の語・負の相対ジャンプ・ポート解決を PicoRuby でも CRuby と同じに出すこと
  def test_picoruby_and_cruby_agree
    with_picoruby do |dir|
      bin = rite([op("LOADI32"), 1, 0xFF, 0xFF, 0xFF, 0xFF, op("NOP"), op("GETGV"), 2, 0, op("JMP"), 0xFF, 0xF9],
                 syms: ["$BUTTON"])
      assert_equal FpgaRom.from_binary(bin).hex, picoruby_convert(dir, bin)
    end
  end

  def test_picoruby_converter_stops_with_the_location
    with_picoruby do |dir|
      e = assert_raises(FpgaConverter::Error) do
        picoruby_convert(dir, rite([op("NOP"), op("ARYCAT"), 1, op("STOP")]))
      end
      assert_match(/unsupported instruction\(s\): ARYCAT at byte 001/, e.message)
      e = assert_raises(FpgaConverter::Error) { picoruby_convert(dir, rite([op("STOP")], nregs: 17), max_regs: 16) }
      assert_match(/needs 17 registers/, e.message)
    end
  end

  def test_rejects_other_rite_versions
    bin = rite([op("STOP")]).sub("RITE0400", "RITE0300")
    assert_raises(Rite::Error) { FpgaRom.from_binary(bin) }
  end
end
