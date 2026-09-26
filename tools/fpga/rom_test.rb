require_relative "test_helper"
require_relative "converter"
require "tmpdir"
require "open3"

class FpgaRomTest < Minitest::Test
  include FpgaTestHelper

  # fpga/corpus/<name>.dump (mrbc -v の命令行、プレリュード込み) と、変換結果を1命令ずつ突き合わせる
  def test_corpus_matches_mrbc_dump
    names = Dir[File.join(CORPUS, "*.mrb")].map { |p| File.basename(p, ".mrb") }.sort
    refute_empty names
    names.each do |name|
      image = FpgaRom.from_binary(File.binread(File.join(CORPUS, "#{name}.mrb")))
      # dump は irep ごとの命令の行 ("irep" で区切る。順は ROM の並びと同じ)。ROM に置かなかった irep (呼ばれないメソッド) は除く
      groups = []
      File.readlines(File.join(CORPUS, "#{name}.dump"), chomp: true).each do |l|
        l == "irep" ? groups << [] : groups.last << l.split(/\s+/, 4)
      end
      assert_equal image.ireps.size, groups.size, name
      dump = groups.each_with_index.flat_map { |g, i| image.ireps[i].base ? g : [] }
      # 元の命令ごとの先頭の語 (block_given? は数語になり、TABLE・本体の ENTER・メソッド表は変換器が足す)
      firsts = image.words.select(&:first)
      pc_of = firsts.to_h { |w| [[w.irep.index, w.insn.addr], w.pc] }
      assert_equal dump.size, firsts.size, name
      dump.zip(firsts).each do |(_line, addr, opname, rest), w|
        where = "#{name} irep #{w.irep.index} byte #{addr}"
        assert_equal addr.to_i, w.insn.addr, where
        # mrbc -v は ARRAY2 も "ARRAY" と表示する
        assert_equal opname, w.insn.name == "ARRAY2" ? "ARRAY" : w.insn.name, where
        got = FpgaIsa::OPS[w.op].name
        assert_includes [w.insn.name, *REWRITTEN[w.insn.name]], got, where
        fields = rest.to_s.split(/[\t ]+/).reject { |f| f.start_with?(";") }
        check_operands(where, opname, fields, w, pc_of, image)
      end
    end
  end

  # 別の命令に置き換わるもの
  REWRITTEN = {
    "ENTER" => %w[NOP], "LAMBDA" => %w[BLOCK], "SENDB" => %w[SEND ARRAY MOVE], "SSENDB" => %w[SSEND ARRAY MOVE], "MODULE" => %w[CLASS],
    "LOADSELF" => %w[MOVE], "RETSELF" => %w[RETURN], "RETTRUE" => %w[LOADTRUE], "RETFALSE" => %w[LOADFALSE],
    "SEND" => %w[ARRAY MOVE], "SUPER" => %w[ARRAY MOVE], # キーワード引数は Hash にしてから呼ぶ
    "KARG" => %w[MOVE], "KEY_P" => %w[MOVE], "KEYEND" => %w[MOVE],
    "GETCONST" => %w[CLASS], "SSEND0" => %w[BLKPUSH LOADNIL], "SSEND" => %w[LOADNIL ARRAY MOVE],
    "GETCV" => %w[GETCONST], "SETCV" => %w[SETCONST], "GETMCNST" => %w[CLASS GETCONST], "SETMCNST" => %w[SETCONST],
    "GETGV" => %w[GETCONST], "SETGV" => %w[SETCONST], # ポートでないグローバル変数
    "JMPUW" => %w[JMP], "STRCAT" => %w[SEND], "LOADL" => %w[LOADI32],
    "HASH" => %w[ARRAY], "HASHADD" => %w[ARRAY], "HASHCAT" => %w[SEND], "RANGE_INC" => %w[SEND], "RANGE_EXC" => %w[SEND]
  }.freeze

  def check_operands(where, opname, fields, w, pc_of, image)
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
                "LOADI32" => ((w.b << 16) | w.c) - (w.b >= 0x8000 ? 2**32 : 0), "LOADINEG" => -w.b }.fetch(opname)
      assert_equal value, fields[1].to_i, where
    when "ADDI", "SUBI"
      assert_equal ["R#{w.a}", w.b.to_s], fields[0, 2], where
    when "ADDILV", "SUBILV"
      assert_equal ["R#{w.a}", "R#{w.b}", w.c.to_s], fields[0, 3], where
    when "NOP", "RETNIL", "STOP"
      assert_equal 0, w.a, where
    when "BREAK"
      assert_equal "R#{w.a}", fields[0], where
    when "ENTER"
      assert_equal fields[0].split(":").first.to_i, w.a, where # 必須の引数の数
      assert_equal w.irep.nregs, w.b, where                    # 埋める nregs
    when "TDEF", "SDEF"
      assert_equal ["R#{w.a}", fields[1]], ["R#{w.a}", ":#{image.symbols[w.b]}"], where
    when "LOADSYM"
      assert_equal ["R#{w.a}", ":#{image.symbols[w.b]}"], fields[0, 2], where
    when "SEND", "SEND0", "SSEND", "SSEND0"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal fields[1], ":#{image.symbols[w.b]}", where
      n = opname.end_with?("0") ? "0" : fields[2].delete("n=")
      assert_equal (n == "*" ? 15 : n.to_i), w.c & 0x7F, where # n=* は splat (R[a+1] が引数の配列)
    when "CLASS"
      assert_equal "R#{w.a}", fields[0], where
      assert_equal fields[1].delete(":"), (image.class_names[w.b] || FpgaIsa::CLASSES.to_h.invert[w.b]).split("::").last, where # class A::B の dump は B
    when "SETCONST"
      assert_equal "R#{w.a}", fields[1], where
    # インスタンス変数は b = 名前のシンボル番号 (オブジェクトの何番目かは実行時にメソッド表で引く)
    when "GETIV"
      assert_equal ["R#{w.a}", fields[1]], ["R#{w.a}", image.symbols[w.b]], where
      assert_equal "R#{w.a}", fields[0], where
    when "SETIV"
      assert_equal [fields[0], fields[1]], [image.symbols[w.b], "R#{w.a}"], where
    when "APOST"
      assert_equal ["R#{w.a}", w.b.to_s, w.c.to_s], fields[0, 3], where
    when "ARYPUSH"
      assert_equal ["R#{w.a}", w.b.to_s], fields[0, 2], where
    when "ARGARY" # b は mruby のまま (m1:r:m2:lv)
      assert_equal ["R#{w.a}", [(w.b >> 11) & 0x3F, (w.b >> 10) & 1, (w.b >> 5) & 0x1F, w.b & 0xF].join(":")], fields[0, 2], where
    # super は b = 今のメソッドの名前、c = 引数の数 | 0x80 (ブロックの枠は必ず渡す)
    when "SUPER"
      n = fields[1].delete("n=")
      assert_equal ["R#{w.a}", (n == "*" ? 15 : n.to_i) | 0x80], [fields[0], w.c], where
      refute_nil image.symbols[w.b], where
    else
      assert_equal "R#{w.a}", fields[0], where
    end
  end

  # pc 0 は TABLE (a = メソッド表の大きさの log2、b = 表の先頭、c = シンボル表の先頭)。
  # 並びはプログラム、データ (文字列とシンボルの名前)、シンボル表、メソッド表
  def test_rom_starts_with_the_table_word
    image = FpgaRom.from_binary(rite([op("LOADI32"), 1, 0x12, 0x34, 0x56, 0x78, op("STOP")]))
    assert_equal "TABLE", FpgaIsa::OPS[image.words[0].op].name
    assert_equal [image.table_size.bit_length - 1, image.table_base, image.symtab], [image.words[0].a, image.words[0].b, image.words[0].c]
    assert_equal [5, image.symtab + image.symbols.size], [image.data_base, image.table_base]
    assert_equal image.table_base + image.table_size, image.words.size
    assert_equal %w[CLASS SEND0], image.words[1, 2].map { |w| FpgaIsa::OPS[w.op].name } # main を作る
    assert_equal "0f0112345678", image.words[3].hex
    assert_equal "760000000000", image.words[4].hex
  end

  def test_jump_becomes_absolute_word_address
    # 0: JMP +1 (byte 3 -> byte 4), 3: NOP, 4: STOP  (pc は TABLE と main を作る2語の分 3 ずれる)
    image = FpgaRom.from_binary(rite([op("JMP"), 0x00, 0x01, op("NOP"), op("STOP")]))
    assert_equal 5, image.words[3].b
    # 後ろ向き: 0: NOP, 1: JMP -4 (byte 4 -> byte 0)
    image = FpgaRom.from_binary(rite([op("NOP"), op("JMP"), 0xFF, 0xFC]))
    assert_equal 3, image.words[4].b
  end

  def test_gvar_becomes_port
    image = FpgaRom.from_binary(rite([op("GETGV"), 1, 0, op("SETGV"), 1, 1, op("STOP")], syms: ["$BUTTON", "$LED2"]))
    assert_equal 2, image.words[3].b
    assert_equal 1, image.words[4].b
  end

  def test_rejects_unsupported_instruction_with_location
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("NOP"), op("SCLASS"), 1, op("STOP")])) }
    assert_match(/unsupported instruction\(s\): SCLASS at byte 001/, e.message)
  end

  # 呼び出しは b = シンボルの番号、c = 引数の数 | ブロックを渡す印 << 7。演算の落ち先のシンボルは 0 から固定
  def test_calls_carry_symbol_numbers
    image = FpgaRom.from_binary(rite([op("SEND0"), 1, 0, op("SSEND"), 1, 1, 2, op("STOP")], syms: %w[puts foo]))
    assert_equal FpgaIsa::OP_SYMS, image.symbols[0, FpgaIsa::OP_SYMS.size]
    assert_equal ["SEND0", "puts", 0], [FpgaIsa::OPS[image.words[3].op].name, image.symbols[image.words[3].b], image.words[3].c]
    assert_equal ["SSEND", "foo", 2], [FpgaIsa::OPS[image.words[4].op].name, image.symbols[image.words[4].b], image.words[4].c]
    blk = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")], nregs: 3)
    bin = rite([op("LOADI_3"), 1, op("BLOCK"), 2, 0, op("SENDB"), 1, 0, 0, op("STOP")], syms: ["select"], reps: [blk])
    w = FpgaRom.from_binary(bin).words[5]
    assert_equal ["SEND", 0x80], [FpgaIsa::OPS[w.op].name, w.c]
  end

  # def two; 2; end; two  →  (Object, :two) → メソッドの先頭 pc がメソッド表に入る。ENTER の b は nregs
  def test_methods_go_into_the_table
    child = irep_record([op("ENTER"), 0, 0, 0, op("LOADI_2"), 2, op("RETURN"), 2], nregs: 3)
    bin = rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("STOP")], syms: ["two"], reps: [child])
    image = FpgaRom.from_binary(bin)
    assert_equal %w[TABLE CLASS SEND0 TDEF SSEND0 STOP ENTER LOADI_2 RETURN], image.words.first(9).map { |w| FpgaIsa::OPS[w.op].name }
    assert_equal [0, 3], [image.words[6].a, image.words[6].b]
    assert_equal 6, lookup(image, FpgaIsa::CLS_OBJECT, "two")
    assert_equal 6, lookup(image, FpgaIsa::CLS_INT, "two") # Integer から親の Object へ
    assert_match(/# irep 1  nregs 3\n   6  000  ENTER/, image.listing)
  end

  # 同じ名前を2回 def したら後の定義 (静的に決める)
  def test_later_definition_wins
    one = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")])
    two = irep_record([op("ENTER"), 0, 0, 0, op("RETNIL")])
    bin = rite([op("TDEF"), 1, 0, 0, op("TDEF"), 1, 0, 1, op("STOP")], syms: ["f"], reps: [one, two])
    image = FpgaRom.from_binary(bin)
    assert_equal image.ireps[2].base, lookup(image, FpgaIsa::CLS_OBJECT, "f")
  end

  # ENTER: a = 必須、b = nregs、c = 省略可能 | 残り << 5 | 後ろの必須 << 6 | kd << 11。kd (キーワード引数) なら回路が空の Hash を
  # 作ることがあるので、プレリュードの Hash の形を確かめる (プレリュードの無いこの program では止まる)
  def test_enter_carries_the_parameter_shape
    params = irep_record([op("ENTER"), 0x04, 0x30, 0x80, op("RETNIL")], nregs: 7) # 1:1:1:1:0:0:0 (m1 o r m2)
    image = FpgaRom.from_binary(rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("STOP")], syms: ["f"], reps: [params]))
    enter = image.words.find { |w| FpgaIsa::OPS[w.op]&.name == "ENTER" }
    assert_equal [1, 7, 1 | (1 << 5) | (1 << 6)], [enter.a, enter.b, enter.c]
    kw = irep_record([op("ENTER"), 0x00, 0x00, 0x04, op("RETNIL")]) # 0:0:0:0:1:0:0 (key 1)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("TDEF"), 1, 0, 0, op("SSEND0"), 1, 0, op("STOP")], syms: ["f"], reps: [kw])) }
    assert_match(/the prelude's Hash has instance variables \[\]/, e.message)
  end

  # キーワード引数: 呼ぶ側は組を Hash にして (ARRAY、__to_hash)、印 KW (c の bit 8) 付きで呼ぶ。KARG は Hash のメソッドの呼び出し
  def test_keyword_calls_are_lowered
    begin
      image = FpgaRom.from_binary(File.binread(File.join(CORPUS, "kwargs.mrb")))
      sends = image.words.select { |w| w.insn && FpgaIsa::OPS[w.op].name == "SEND" && (w.c & FpgaRom::KW) != 0 }
      refute_empty sends
      enters = image.words.select { |w| w.insn && FpgaIsa::OPS[w.op].name == "ENTER" && (w.c >> 11) == 1 }
      refute_empty enters
      assert(image.words.any? { |w| w.insn&.name == "KARG" && FpgaIsa::OPS[w.op].name == "MOVE" })
    end
  end

  # クラス: CLASS は R[a] = クラスの即値、本体の EXEC は b = 本体の先頭 (変換器が足した ENTER)。
  # クラスメソッドはメタクラス (番号 | META)、親クラスへの輪、定数の字句の入れ子
  def test_classes_and_constants
    with_mrbc do
      image = compile(<<~RUBY)
        class Foo
          X = 1
          def self.make = X
          def get = X
        end
        class Bar < Foo
          def get = 2
        end
        $LED = Bar.make + Bar.new.get + Foo.new.get
      RUBY
      foo = image.class_names.key("Foo")
      bar = image.class_names.key("Bar")
      assert_equal [FpgaIsa::FIRST_USER_CLASS, FpgaIsa::FIRST_USER_CLASS + 1], [foo, bar]
      exec = image.words.find { |w| FpgaIsa::OPS[w.op]&.name == "EXEC" }
      assert_equal "ENTER", FpgaIsa::OPS[image.words[exec.b].op].name
      assert lookup(image, FpgaIsa::META | foo, "make")
      assert_equal lookup(image, FpgaIsa::META | foo, "make"), lookup(image, FpgaIsa::META | bar, "make")
      refute_equal lookup(image, foo, "get"), lookup(image, bar, "get")
      # Bar は GETCONST ではなくクラスの即値 (CLASS)
      assert(image.words.any? { |w| FpgaIsa::OPS[w.op]&.name == "CLASS" && w.b == bar && w.insn&.name == "GETCONST" })
    end
  end

  # ブロックの外の変数は GETUPVAR c = 深さ + 1 で読む。深さを超える参照と、ブロックの外の break / return は止める
  def test_break_and_upvar_need_an_enclosing_block
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("BREAK"), 1, op("STOP")])) }
    assert_match(/break at byte 000 is not inside a block/, e.message)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("GETUPVAR"), 1, 1, 0, op("STOP")])) }
    assert_match(/GETUPVAR at byte 000 reaches 1 levels out, the block is 0 deep/, e.message)
    blk = irep_record([op("ENTER"), 0, 0, 0, op("GETUPVAR"), 1, 1, 0, op("RETURN"), 1], nregs: 3)
    words = FpgaRom.from_binary(rite([op("BLOCK"), 1, 0, op("STOP")], reps: [blk])).words
    assert_equal ["GETUPVAR", 1, 1, 1], [FpgaIsa::OPS[words[6].op].name, words[6].a, words[6].b, words[6].c]
    top_return = irep_record([op("ENTER"), 0, 0, 0, op("RETURN_BLK"), 1], nregs: 3)
    e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("BLOCK"), 1, 0, op("STOP")], reps: [top_return])) }
    assert_match(/return inside a block at irep 1 byte 004 is not inside a method or a lambda/, e.message)
  end

  # lambda { } と -> { } は lambda の印 (c の 0x80) を付けた BLOCK (引数と nregs はブロックの ENTER が持つ)。
  # 一番外の lambda の中の return は通す
  def test_lambdas_are_marked
    blk = irep_record([op("ENTER"), 0x04, 0, 0, op("RETURN_BLK"), 1], nregs: 3) # |x| return x
    bin = rite([op("BLOCK"), 2, 0, op("SSENDB"), 1, 0, 0, op("STOP")], syms: ["lambda"], reps: [blk])
    words = FpgaRom.from_binary(bin).words
    assert_equal ["BLOCK", 0x80], [FpgaIsa::OPS[words[3].op].name, words[3].c]
    words = FpgaRom.from_binary(rite([op("LAMBDA"), 1, 0, op("STOP")], reps: [blk])).words
    assert_equal ["BLOCK", 0x80], [FpgaIsa::OPS[words[3].op].name, words[3].c]
    words = FpgaRom.from_binary(rite([op("BLOCK"), 2, 0, op("SSENDB"), 1, 0, 0, op("STOP")], syms: ["proc"], reps: [
      irep_record([op("ENTER"), 0x04, 0, 0, op("RETURN"), 1], nregs: 3)
    ])).words
    assert_equal 0, words[3].c # proc は印なし
  end

  # インスタンス変数は子クラスが親の並びの後ろに足す。(cls, :@x) と attr の (cls, :x) (cls, :x=) は
  # 何番目かを指し、(cls, NIVARS) は数。include した module の ivar はそのクラスの並びに入る
  def test_ivar_layout_and_attrs
    with_mrbc do
      image = compile(<<~RUBY)
        module Named
          def name = @name
          def name!(n) = (@name = n)
        end
        class P
          attr_reader :x
          attr_accessor :y
          def initialize(x) = (@x = x)
        end
        class Q < P
          include Named
          def initialize(x, z)
            super(x)
            @z = z
          end
        end
        $LED = Q.new(1, 2).is_a?(P) ? 1 : 0
      RUBY
      p_id = image.class_names.key("P")
      q_id = image.class_names.key("Q")
      assert_equal [FpgaIsa::TGT_IVAR << 14 | 0, FpgaIsa::TGT_IVSET << 14 | 1], [full_lookup(image, p_id, "x"), full_lookup(image, p_id, "y=")]
      assert_equal [FpgaIsa::TGT_IVAR << 14 | 0, FpgaIsa::TGT_IVAR << 14 | 1], [full_lookup(image, p_id, "@x"), full_lookup(image, p_id, "@y")]
      # Q の並び: @x @y (P から) + @z + @name (include)。Q の行は増えた分だけで、@x は親を辿って引く
      assert_equal [0, 2], [lookup(image, q_id, "@x"), full_lookup(image, q_id, "@z") & 0x3FFF]
      assert_equal 3, full_lookup(image, q_id, "@name") & 0x3FFF
      assert_nil full_lookup(image, q_id, "@x")
      assert_equal [2, 4], [nivars(image, p_id), nivars(image, q_id)]
      # is_a? が出てくるので ISA の行がある (祖先を辿らずに1回で引く)
      assert probe(image, FpgaIsa::ISA_BIT | q_id, p_id, image.table_size - 1)
      assert probe(image, FpgaIsa::ISA_BIT | q_id, image.class_names.key("Named"), image.table_size - 1)
      refute probe(image, FpgaIsa::ISA_BIT | p_id, q_id, image.table_size - 1)
    end
  end

  # 黙って違う動きをするより、変換で止める
  def test_rejects_unsupported_object_features
    with_mrbc do
      { "class A; extend Comparable; end" => /extend in a class body/,
        "class A; @n = 1; end" => /class-level instance variables/,
        "class A; def f = [1].each { super() }; end" => /super inside a block/ }.each do |src, msg|
        e = assert_raises(FpgaRom::Error) { compile(src) }
        assert_match msg, e.message, src
      end
    end
  end

  # pool: 文字列はデータ領域 (同じ中身は1つ) に置き STRING の b / c がその場所と長さ。LOADL は 32bit の整数だけ
  def test_pool_strings_and_integers
    image = FpgaRom.from_binary(rite([op("STRING"), 1, 0, op("STRING"), 2, 1, op("STRING"), 3, 0, op("LOADL"), 4, 3, op("STOP")],
                                     pool: ["hello", "", "hello", -7]))
    s1, s2, s3, l = image.words[3, 4]
    assert_equal [image.data_base, 5], [s1.b, s1.c]
    assert_equal [s1.b, 5], [s3.b, s3.c] # 同じ中身
    assert_equal 0, s2.c
    assert_equal ["LOADI32", 0xFFFF, 0xFFF9], [FpgaIsa::OPS[l.op].name, l.b, l.c]
    assert_equal [0x6c6c6568, 0x6f], [image.words[s1.b].value & 0xFFFF_FFFF, image.words[s1.b + 1].value] # バイト j は bit 8j から
    # シンボル表: {データの語アドレス, 長さ}
    sym = image.symbols.index("initialize")
    e = image.words[image.symtab + sym]
    assert_equal "initi", [image.words[e.b].value, image.words[e.b + 1].value].pack("VV")[0, 5]
    assert_equal 10, e.c
    { :float => /Float/, 2**40 => /does not fit in 32 bits/ }.each do |v, msg|
      e = assert_raises(FpgaRom::Error) { FpgaRom.from_binary(rite([op("LOADL"), 1, 0, op("STOP")], pool: [v])) }
      assert_match msg, e.message
    end
  end

  # io_map.rb に無いグローバル変数は定数の表に置き、一番外の先頭で nil にする (代入前に読むと nil)
  def test_general_globals_start_as_nil
    image = FpgaRom.from_binary(rite([op("GETGV"), 1, 0, op("SETGV"), 1, 1, op("STOP")], syms: ["$foo", "$LED2"]))
    names = image.words.first(6).map { |w| FpgaIsa::OPS[w.op].name }
    assert_equal %w[TABLE LOADNIL SETCONST CLASS SEND0 GETCONST], names
    assert_equal image.words[2].b, image.words[5].b
    assert_equal ["SETGV", 1], [FpgaIsa::OPS[image.words[6].op].name, image.words[6].b] # $LED2 はポートのまま
  end

  # A::X と class A::B は GETCONST / GETMCNST の連なりから静的に解く。知らない入れ物は止める
  def test_scoped_constants
    with_mrbc do
      image = compile(<<~RUBY)
        module A
          X = 2
          class B; end
        end
        class A::C < A::B; end
        A::Y = 3
        $LED = A::X + A::Y
        $LED2 = A::C.new.is_a?(A::B)
      RUBY
      assert image.class_names.key("A::C")
      e = assert_raises(FpgaRom::Error) { compile("$LED = Nope::X\n") }
      assert_match(/not a known class or module/, e.message)
      e = assert_raises(FpgaRom::Error) { compile("module A; end\n$LED = A::Q\n") }
      assert_match(/A::Q .* is not assigned anywhere/, e.message)
    end
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
      image = FpgaRom.from_binary(File.binread(mrb), mrb, FpgaIsa::RF_SIZE)
      assert_equal File.read(mrb.sub(/\.mrb\z/, ".hex")), image.hex, mrb
      assert_equal File.read(mrb.sub(/\.mrb\z/, ".lst")), image.listing, mrb
    end
  end

  def with_picoruby
    skip "vendor/picoruby/bin/picoruby is not built" unless File.executable?(PICORUBY)
    Dir.mktmpdir { |dir| yield dir }
  end

  def with_mrbc
    skip "vendor/picoruby/bin/mrbc is not built" unless File.executable?(MRBC)
    yield
  end

  # プレリュード無しで compile して変換する
  def compile(src)
    Dir.mktmpdir do |dir|
      rb = File.join(dir, "in.rb")
      out = File.join(dir, "in.mrb")
      File.write(rb, src)
      _o, err, st = Open3.capture3(MRBC, "-o", out, rb)
      raise err unless st.success?
      FpgaRom.from_binary(File.binread(out))
    end
  end

  # メソッド表を ref_vm.rb と同じ手順で引く (見つからなければ nil)
  def lookup(image, cls, name)
    sym = image.symbols.index(name)
    return nil unless sym
    mask = image.table_size - 1
    FpgaIsa::MAX_SUPER_DEPTH.times do
      t = probe(image, cls, sym, mask)
      return t & 0x3FFF if t
      cls = probe(image, cls, FpgaIsa::SUPER_SYM, mask)
      return nil unless cls
    end
    nil
  end

  # 種類の bit も含めた行の値 (親は辿らない)
  def full_lookup(image, cls, name)
    probe(image, cls, image.symbols.index(name), image.table_size - 1)
  end

  def nivars(image, cls)
    probe(image, cls, FpgaIsa::NIVARS_SYM, image.table_size - 1)
  end

  def probe(image, cls, sym, mask)
    h = FpgaIsa.table_hash(cls, sym, mask)
    image.table_size.times do |i|
      w = image.words[image.table_base + ((h + i) & mask)].value
      return nil if w == FpgaRom::PAD
      return w & 0xFFFF if (w >> 32) == cls && ((w >> 16) & 0xFFFF) == sym
    end
    nil
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
        picoruby_convert(dir, rite([op("NOP"), op("SCLASS"), 1, op("STOP")]))
      end
      assert_match(/unsupported instruction\(s\): SCLASS at byte 001/, e.message)
      e = assert_raises(FpgaConverter::Error) { picoruby_convert(dir, rite([op("STOP")], nregs: 17), max_regs: 16) }
      assert_match(/needs 17 registers/, e.message)
    end
  end

  def test_rejects_other_rite_versions
    bin = rite([op("STOP")]).sub("RITE0400", "RITE0300")
    assert_raises(Rite::Error) { FpgaRom.from_binary(bin) }
  end
end
