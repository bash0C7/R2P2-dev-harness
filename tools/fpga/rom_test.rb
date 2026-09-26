require_relative "test_helper"
require_relative "rom"

class FpgaRomTest < Minitest::Test
  include FpgaTestHelper

  # fpga/corpus/<name>.dump (mrbc -v の命令行) と、変換結果を1命令ずつ突き合わせる
  def test_corpus_matches_mrbc_dump
    names = Dir[File.join(CORPUS, "*.mrb")].map { |p| File.basename(p, ".mrb") }.sort
    refute_empty names
    names.each do |name|
      image = FpgaRom.from_file(File.join(CORPUS, "#{name}.mrb"))
      dump = File.readlines(File.join(CORPUS, "#{name}.dump"), chomp: true).map { |l| l.split(/\s+/, 4) }
      pc_of = image.words.to_h { |w| [w.insn.addr, w.pc] }
      assert_equal dump.size, image.words.size, name
      dump.zip(image.words).each do |(_line, addr, opname, rest), w|
        where = "#{name} byte #{addr}"
        assert_equal addr.to_i, w.insn.addr, where
        assert_equal opname, w.insn.name, where
        assert_equal FpgaIsa.op(opname).num, w.op, where
        fields = rest.to_s.split(/[\t ]+/).reject { |f| f.start_with?(";") }
        check_operands(where, opname, fields, w, pc_of)
      end
    end
  end

  def check_operands(where, opname, fields, w, pc_of)
    case opname
    when "JMP"
      assert_equal pc_of.fetch(fields[0].to_i), w.b, where
    when "JMPIF", "JMPNOT", "JMPNIL"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal pc_of.fetch(fields[1].to_i), w.b, where
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
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("NOP"), op("SEND0"), 1, 0, op("STOP")], syms: ["!"])) }
    assert_match(/unsupported instruction\(s\): SEND0 at byte 001/, e.message)
  end

  def test_rejects_child_irep
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("STOP")], rlen: 1)) }
    assert_match(/child irep/, e.message)
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
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("STOP")], nregs: 17), max_regs: 16) }
    assert_match(/needs 17 registers/, e.message)
  end

  def test_rejects_other_rite_versions
    bin = rite([op("STOP")]).sub("RITE0400", "RITE0300")
    assert_raises(Rite::Error) { FpgaRom.from_binary(bin) }
  end
end
