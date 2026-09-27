require "minitest/autorun"
require "tmpdir"
require_relative "inventory"

# 棚卸し (計画 S2-1) の test: 走査の読み方と、commit した表が今の vendor と host から作り直したものと同じこと
class FpgaV2InventoryTest < Minitest::Test
  I = FpgaV2::Inventory

  def test_presym_names
    skip "presym が無い (rake fpga:picoruby)" unless File.exist?(File.join(I::PRESYM_DIR, "id.h"))
    assert_equal "==", I.sym_name("MRB_OPSYM(eq)")
    assert_equal "include?", I.sym_name("MRB_SYM_Q(include)")
    assert_equal "pos=", I.sym_name("MRB_SYM_E(pos)")
    assert_equal "=~", I.sym_name('mrb_intern_lit(mrb, "=~")')
  end

  def scan_c_text(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.c")
      File.write(path, text)
      I.scan_c(path)
    end
  end

  def test_c_rom_table_and_defines
    skip "presym が無い (rake fpga:picoruby)" unless File.exist?(File.join(I::PRESYM_DIR, "id.h"))
    entries, problems = scan_c_text(<<~C)
      static const mrb_mt_entry foo_rom_entries[] = {
        MRB_MT_ENTRY(foo_size,  MRB_SYM(size),       MRB_ARGS_NONE()),
        MRB_MT_ENTRY(foo_init,  MRB_SYM(initialize), MRB_ARGS_ANY() | MRB_MT_PRIVATE),
      };
      static void helper(mrb_state *mrb, struct RClass *k) { mrb_define_method_id(mrb, k, MRB_SYM(late), f_late, MRB_ARGS_NONE()); }
      void init(mrb_state *mrb) {
        struct RClass *k = mrb_define_class_id(mrb, MRB_SYM(Foo), mrb->object_class);
        MRB_MT_INIT_ROM(mrb, k, foo_rom_entries);
        struct RClass *e = mrb->eException_class = mrb_define_class_id(mrb, MRB_SYM(Exception), mrb->object_class);
        mrb_define_class_method_id(mrb, e, MRB_SYM(make), f_make, MRB_ARGS_NONE());
        mrb_define_private_method_id(mrb, mrb_singleton_class_ptr(mrb, mrb_obj_value(k)), MRB_SYM(hidden), f_h, MRB_ARGS_NONE());
        mrb_undef_class_method_id(mrb, k, MRB_SYM(new));
      }
    C
    got = entries.map { |e| [e.kind, e.owner, e.name, e.src.to_s.split(":").last] }
    assert_includes got, ["pub", "Foo", "size", "foo_size"]
    assert_includes got, ["priv", "Foo", "initialize", "foo_init"]
    assert_includes got, ["pub", "Foo", "late", "f_late"] # helper は定義より前の行で k を使う
    assert_includes got, ["sing", "Exception", "make", "f_make"] # e = mrb->eException_class = mrb_define_class_id(...)
    assert_includes got, ["spriv", "Foo", "hidden", "f_h"]
    assert_includes got, ["sing", "Foo", "new", "undef"]
    assert_includes got.map { |g| g[0, 3] }, ["const", "Object", "Foo"]
    assert_equal [], problems
  end

  def scan_rb_text(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      File.write(path, text)
      I.scan_rb(path).map { |e| [e.kind, e.owner, e.name] }
    end
  end

  def test_mrblib_visibility_and_owners
    got = scan_rb_text(<<~RUBY)
      class << self
        def top_helper; end
      end
      def self.top_single; end
      module M
        class << self
          def open; end
          private
          def hidden; end
          def shown; end
          public :shown
        end
        module_function
        def mf; end
      end
      class A::B < C
        attr_accessor :v
        private def p1; end
        protected
        def p2; end
        alias p3 p2
        K = 1
      end
    RUBY
    %w[top_helper top_single].each { |n| assert_includes got, ["sing", "main", n] }
    assert_includes got, ["sing", "M", "open"]
    assert_includes got, ["spriv", "M", "hidden"]
    assert_includes got, ["sing", "M", "shown"]
    assert_includes got, ["sing", "M", "mf"]
    assert_includes got, ["priv", "M", "mf"]
    assert_includes got, ["const", "A", "B"]
    assert_includes got, ["pub", "A::B", "v"]
    assert_includes got, ["pub", "A::B", "v="]
    assert_includes got, ["priv", "A::B", "p1"]
    assert_includes got, ["prot", "A::B", "p2"]
    assert_includes got, ["prot", "A::B", "p3"]
    assert_includes got, ["const", "A::B", "K"]
  end

  # 板の gem の集合は R2P2 の build_config から出す (gembox の条件は板: vm_mruby、posix でない)
  def test_board_gems_follow_r2p2_config
    board = I.board_gems
    %w[picoruby-gpio picoruby-machine picoruby-shell picoruby-littlefs picoruby-vfs mruby-task].each { |g| assert_includes board, g }
    %w[picoruby-bin-picoruby picoruby-posix-io].each { |g| refute_includes board, g } # posix の build だけの gem
  end

  # commit した表は、今の vendor と host から作り直したものと同じ (手で書き換えない、古くならない)
  def test_committed_tables_are_current
    pico = FpgaConverter.default_picoruby
    skip "host の picoruby が無い (rake fpga:picoruby)" unless File.executable?(pico)
    r = I.build(picoruby: pico)
    assert_equal File.read(I::OUT), I.tsv(r), "rake fpga:v2:inventory で作り直す"
    assert_equal File.read(I::UNMATCHED), I.unmatched_tsv(r), "rake fpga:v2:inventory で作り直す"
  end
end
