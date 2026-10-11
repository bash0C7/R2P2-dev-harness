# rite_core (fpga/rtl/rite_core.sv) の起動の像。mrb_open の C の init (class.c の mrb_init_class、kernel.c、numeric.c、
# gem の init の mrb_define_*) が作る状態のうち、回路が要るものを ROM の先頭に置く形にする。
#
# - presym: 回路の C の関数と定数が名前で使う sym (mruby の presym に当たる)。番号は並びの順 (1 から)
# - クラス: superclass、メソッドの表を持つクラス (include の iclass は module を指す)、特異クラス、外側、種類
# - 定数、C の関数のメソッド (クラス、名前、関数の番号、private)、object (main)
#
# 回路は同じ番号を fpga/rtl/rite_image_pkg.sv (この道具が作る、commit する) で知る。ROM の形:
#   "RIMG" nsym { len name }... ncls { super mtc sclass outer flags name }...
#   nconst { cls sym tag val(4, big endian) }... nmeth { cls mid flags tgt }... nobj { cls }...
# flags (クラス): bit0 module、bit1 特異クラス、bit2 iclass。flags (メソッド): bit7 private、bit6..5 種類 (0 irep、1 C の関数、2 attr_reader)
module FpgaRiteImage
  PKG = File.expand_path("../../fpga/rtl/rite_image_pkg.sv", __dir__)

  # [SV の名前, sym]
  PRESYM = [
    %w[GPIO GPIO], %w[KERNEL Kernel], %w[OBJECT Object],
    %w[IN IN], %w[OUT OUT], %w[HIGH_Z HIGH_Z], %w[PULL_UP PULL_UP], %w[PULL_DOWN PULL_DOWN],
    %w[OPEN_DRAIN OPEN_DRAIN], %w[ALT ALT],
    %w[NEW new], %w[INITIALIZE initialize], %w[AT_PIN @pin],
    %w[UINIT _init], %w[SET_DIR_AT set_dir_at], %w[WRITE write], %w[SLEEP_MS sleep_ms],
    %w[MODULE_FUNCTION module_function], %w[ATTR_READER attr_reader],
    %w[AND &], %w[OR |], %w[RSHIFT >>], %w[EQQ ===], %w[NOT !]
  ].freeze

  # [SV の名前, superclass, mtc (メソッドの表を持つクラス、nil は自分), 特異クラス, 外側, 種類, 名前の sym (SV の名前)]
  # 種類: nil / :module / :singleton / :iclass。mruby の class.c の boot_defclass と make_metaclass、mrb_include_module の並び。
  # Comparable、Numeric、Object と BasicObject 以外の特異クラスは、メソッドを持たないので省く (乖離は計画の記録)
  CLASSES = [
    ["BASIC",   nil,      nil,      "S_BASIC",  nil, nil, nil],
    ["OBJECT",  "I_KERNEL", nil,    "S_OBJECT", nil, nil, "OBJECT"],
    ["MODULE",  "OBJECT", nil,      nil,        nil, nil, nil],
    ["CLASS",   "MODULE", nil,      nil,        nil, nil, nil],
    ["KERNEL",  nil,      nil,      "S_KERNEL", nil, :module, "KERNEL"],
    ["I_KERNEL", "BASIC", "KERNEL", nil,        nil, :iclass, nil],
    ["INTEGER", "OBJECT", nil,      nil,        nil, nil, nil],
    ["NIL",     "OBJECT", nil,      nil,        nil, nil, nil],
    ["TRUE",    "OBJECT", nil,      nil,        nil, nil, nil],
    ["FALSE",   "OBJECT", nil,      nil,        nil, nil, nil],
    ["SYMBOL",  "OBJECT", nil,      nil,        nil, nil, nil],
    ["PROC",    "OBJECT", nil,      nil,        nil, nil, nil],
    ["GPIO",    "OBJECT", nil,      "S_GPIO",   nil, nil, "GPIO"],
    ["S_BASIC",  "CLASS",    nil, nil, nil, :singleton, nil],
    ["S_OBJECT", "S_BASIC",  nil, nil, nil, :singleton, nil],
    ["S_KERNEL", "MODULE",   nil, nil, nil, :singleton, nil],
    ["S_GPIO",   "S_OBJECT", nil, nil, nil, :singleton, nil]
  ].freeze

  # C の関数 (回路が実行する)。[SV の名前, 写し元]
  FUNCS = [
    ["F_NEW",          "class.c mrb_instance_new"],
    ["F_DO_NOTHING",   "class.c mrb_do_nothing"],
    ["F_UINIT",        "picoruby-gpio gpio.c mrb__init"],
    ["F_SET_DIR_AT",   "picoruby-gpio gpio.c mrb_s_set_dir_at"],
    ["F_WRITE",        "picoruby-gpio gpio.c mrb_write"],
    ["F_SLEEP_MS",     "mruby-task task.c mrb_f_sleep_ms"],
    ["F_MODFUNC",      "class.c mrb_mod_module_function"],
    ["F_ATTR_READER",  "class.c mrb_mod_attr_reader"],
    ["F_AND",          "numeric.c int_and"],
    ["F_OR",           "numeric.c int_or"],
    ["F_RSHIFT",       "numeric.c int_rshift"],
    ["F_EQQ",          "kernel.c mrb_eqq_m"],
    ["F_NOT",          "class.c mrb_bob_not"]
  ].freeze

  # [クラス, 名前, 関数, private]
  METHODS = [
    ["CLASS",   "NEW",             "F_NEW",         false],
    ["BASIC",   "INITIALIZE",      "F_DO_NOTHING",  true],
    ["BASIC",   "NOT",             "F_NOT",         false],
    ["MODULE",  "MODULE_FUNCTION", "F_MODFUNC",     false],
    ["MODULE",  "ATTR_READER",     "F_ATTR_READER", false],
    ["KERNEL",  "EQQ",             "F_EQQ",         false],
    ["KERNEL",  "SLEEP_MS",        "F_SLEEP_MS",    false],
    ["INTEGER", "AND",             "F_AND",         false],
    ["INTEGER", "OR",              "F_OR",          false],
    ["INTEGER", "RSHIFT",          "F_RSHIFT",      false],
    ["GPIO",    "UINIT",           "F_UINIT",       false],
    ["GPIO",    "WRITE",           "F_WRITE",       false],
    ["S_GPIO",  "SET_DIR_AT",      "F_SET_DIR_AT",  false]
  ].freeze

  # picoruby-gpio/include/gpio.h
  GPIO_FLAGS = { "IN" => 1, "OUT" => 2, "HIGH_Z" => 4, "PULL_UP" => 8, "PULL_DOWN" => 16, "OPEN_DRAIN" => 32, "ALT" => 64 }.freeze
  TAGS = { nil: 0, false: 1, true: 2, int: 3, sym: 4, class: 5, obj: 6, proc: 7 }.freeze

  # [クラス, 名前, 種類, 値]
  CONSTS = ([["OBJECT", "GPIO", :class, "GPIO"], ["OBJECT", "KERNEL", :class, "KERNEL"], ["OBJECT", "OBJECT", :class, "OBJECT"]] +
            GPIO_FLAGS.map { |k, v| ["GPIO", k, :int, v] }).freeze

  OBJECTS = ["OBJECT"].freeze  # 0: main

  module_function

  def sym_id(name) = PRESYM.index { |n, _| n == name }&.+(1) || raise("no presym #{name}")
  def class_id(name) = name.nil? ? 0 : (CLASSES.index { |c| c[0] == name }&.+(1) || raise("no class #{name}"))
  def func_id(name) = FUNCS.index { |f, _| f == name } || raise("no func #{name}")

  def image
    b = "RIMG".bytes
    b << PRESYM.size
    PRESYM.each { |_, s| b << s.bytesize; b.concat(s.bytes) }
    b << CLASSES.size
    CLASSES.each do |name, sup, mtc, scls, outer, kind, sym|
      flags = { module: 1, singleton: 2, iclass: 4 }.fetch(kind, 0)
      b.concat([class_id(sup), class_id(mtc || name), class_id(scls), class_id(outer), flags, sym ? sym_id(sym) : 0])
    end
    b << CONSTS.size
    CONSTS.each do |cls, sym, tag, val|
      v = tag == :class ? class_id(val) : val
      b.concat([class_id(cls), sym_id(sym), TAGS.fetch(tag)] + [v].pack("N").bytes)
    end
    b << METHODS.size
    METHODS.each { |cls, mid, f, priv| b.concat([class_id(cls), sym_id(mid), (priv ? 0x80 : 0) | (1 << 5), func_id(f)]) }
    b << OBJECTS.size
    OBJECTS.each { |c| b << class_id(c) }
    b
  end

  def pkg
    lines = ["// 道具 (tools/fpga/rite_image.rb) が作る起動の像の番号。手で直さない (rake fpga:rite:hex で作り直す)",
             "`timescale 1ns / 1ps",
             "// 表として全部並べる (回路が使わない番号もある)",
             "/* verilator lint_off UNUSEDPARAM */",
             "package rite_image_pkg;",
             "  localparam int SW = 8;  // sym の番号の幅",
             "  localparam int CW = 5;  // クラスの番号の幅",
             "  localparam int FW = 4;  // C の関数の番号の幅",
             "  // presym (sym の番号。0 は名前の無い sym)"]
    PRESYM.each { |n, s| lines << "  localparam logic [SW-1:0] N_#{n} = SW'(#{sym_id(n)});  // #{s}" }
    lines << "  // クラス (0 は無い)"
    CLASSES.each { |c| lines << "  localparam logic [CW-1:0] C_#{c[0]} = CW'(#{class_id(c[0])});" }
    lines << "  // C の関数"
    FUNCS.each { |f, src| lines << "  localparam logic [FW-1:0] #{f} = FW'(#{func_id(f)});  // #{src}" }
    lines << "endpackage"
    lines << "/* verilator lint_on UNUSEDPARAM */"
    lines.join("\n") + "\n"
  end
end
