# v2 の起動の像 (設計 §3・§4・§14)。SDRAM に置く記憶の中身を作る。
#
# - firmware (fpga/firmware/*.rb を mrbc で1つの .mrb にしたもの) と、プログラム (と mrblib) の .mrb は **バイト列を変えずに** 置く
# - コアのクラス (mruby の mrb_init_class と同じ親と形) とメタクラスを作り、firmware のクラスの本体の def を ROM のメソッド表にする
#   (mruby が C のメソッドを ROM の表にしているのと同じ。実行時の定義はその上の層)
# - firmware の irep の構造体を作る (プログラムの .mrb は起動後に firmware の loader が同じ形に読む)
# - シンボル表 (presym) と特権の primitive の表
require_relative "layout"
require_relative "ops"

module FpgaV2
  class Image
    include Layout
    class Error < StandardError; end

    MEM_SIZE = 32 * 1024 * 1024
    SYM_CAPA = 65_536
    STACK_VALUES = 65_536 # VM のスタック (値の並び)
    CI_FRAMES = 4096
    CI_SIZE = 64 # フレーム 1 つのバイト数 (ref.rb の CI_*)

    # コアのクラス: [名前, 親, :class / :module, include する module]。mruby の class.c (mrb_init_class)、object.c、numeric.c ... の親と同じ
    CORE = [
      ["BasicObject", nil, :class], ["Object", "BasicObject", :class], ["Module", "Object", :class], ["Class", "Module", :class],
      ["Kernel", nil, :module], ["Comparable", nil, :module], ["Enumerable", nil, :module],
      ["NilClass", "Object", :class], ["TrueClass", "Object", :class], ["FalseClass", "Object", :class],
      ["Numeric", "Object", :class, "Comparable"], ["Integer", "Numeric", :class], ["Float", "Numeric", :class],
      ["Symbol", "Object", :class, "Comparable"], ["String", "Object", :class, "Comparable"],
      ["Array", "Object", :class, "Enumerable"], ["Hash", "Object", :class, "Enumerable"], ["Range", "Object", :class, "Enumerable"],
      ["Proc", "Object", :class],
      ["Exception", "Object", :class], ["ScriptError", "Exception", :class], ["NotImplementedError", "ScriptError", :class],
      ["StandardError", "Exception", :class], ["RuntimeError", "StandardError", :class], ["FrozenError", "RuntimeError", :class],
      ["ArgumentError", "StandardError", :class], ["TypeError", "StandardError", :class], ["NameError", "StandardError", :class],
      ["NoMethodError", "NameError", :class], ["IndexError", "StandardError", :class], ["KeyError", "IndexError", :class],
      ["StopIteration", "IndexError", :class], ["RangeError", "StandardError", :class], ["FloatDomainError", "RangeError", :class],
      ["ZeroDivisionError", "StandardError", :class], ["LocalJumpError", "StandardError", :class],
      ["SystemStackError", "Exception", :class], ["NoMemoryError", "Exception", :class]
    ].freeze
    # Object は Kernel を include する (mruby の mrb_init_kernel)
    CORE_INCLUDES = { "Object" => "Kernel" }.freeze
    # 即値の tag → クラス (回路の class_of が引く表。像の core_classes の並び)
    TAG_CLASSES = %w[NilClass FalseClass TrueClass Integer Symbol Float NilClass NilClass].freeze
    # 組み込みのクラスの表 (layout.rb の CORE_*)
    CORE_TABLE = TAG_CLASSES + %w[Array String Proc Hash Range Object Class Module]

    # 特権の primitive (回路が symbol で引く、設計 §14)。番号は ref.rb の PRIM と同じ並び
    PRIMS = %w[
      __fpga_ld8 __fpga_st8 __fpga_ld32 __fpga_st32 __fpga_ldv __fpga_stv __fpga_addr __fpga_obj __fpga_tag __fpga_mkval
      __fpga_putc __fpga_alloc __fpga_mcache_fill __fpga_mcache_clear __fpga_invoke __fpga_run __fpga_mid __fpga_halt
      __fpga_int __fpga_hi __fpga_lo __fpga_image __fpga_reg __fpga_setreg __fpga_irep __fpga_tclass __fpga_and __fpga_or
      __fpga_xor __fpga_shl __fpga_shr __fpga_copy __fpga_core __fpga_rem __fpga_proc __fpga_frame_vis __fpga_set_caller_vis
      __fpga_class_of __fpga_sendv __fpga_hp __fpga_hlim __fpga_set_heap __fpga_stack_top __fpga_frame_proc
      __fpga_arena
    ].freeze

    # 回路が名前で送るシンボル (演算の落ち先と method_missing。mruby の MRB_OPSYM と同じく presym)
    HW_SYMS = %w[+ - * / == < <= > >= [] []= method_missing].freeze

    attr_reader :mem, :syms, :classes, :top

    MARK_STACK = 256 * 1024 # GC の mark の明示のスタック (語の数)

    # heap_size はヒープのバイト数 (nil は記憶の残り全部)。小さくすると GC が何度も走る (テスト)
    def initialize(firmware:, programs: [], heap_size: nil)
      @fw_bin = firmware
      @programs = programs
      @heap_size = heap_size
      @objs = [] # 像の中のオブジェクト (GC の根)
      @mem = "\0".b * MEM_SIZE
      @brk = IMG_WORDS * WORD
      @syms = {} # 名前 → 番号
    end

    # --- 記憶
    def alloc(n, align = 8)
      @brk = (@brk + align - 1) & -align
      a = @brk
      @brk += n
      raise Error, "image too large" if @brk > MEM_SIZE
      a
    end

    def w32(a, v) = @mem.setbyte(a, (v >> 24) & 0xFF).then { @mem.setbyte(a + 1, (v >> 16) & 0xFF); @mem.setbyte(a + 2, (v >> 8) & 0xFF); @mem.setbyte(a + 3, v & 0xFF) }
    def w16(a, v) = (@mem.setbyte(a, (v >> 8) & 0xFF); @mem.setbyte(a + 1, v & 0xFF))
    def r32(a) = @mem.getbyte(a) << 24 | @mem.getbyte(a + 1) << 16 | @mem.getbyte(a + 2) << 8 | @mem.getbyte(a + 3)

    def wval(a, tag, v)
      v &= 0xFFFF_FFFF_FFFF_FFFF
      w32(a, tag)
      w32(a + 4, 0)
      w32(a + 8, v >> 32)
      w32(a + 12, v & 0xFFFF_FFFF)
    end

    def bytes(s)
      a = alloc(s.bytesize, 4)
      @mem[a, s.bytesize] = s.b
      a
    end

    # --- シンボル (FNV-1a 32bit、開番地法。firmware の intern と同じ)
    def self.sym_hash(name)
      h = 0x811C9DC5
      name.each_byte { |b| h = ((h ^ b) * 0x01000193) & 0xFFFF_FFFF }
      h
    end

    def intern(name)
      name = name.to_s
      return @syms[name] if @syms.key?(name)
      i = Image.sym_hash(name) & (SYM_CAPA - 1)
      i = (i + 1) & (SYM_CAPA - 1) while r32(@sym_table + i * 8) != 0 # 空き = 名前の番地 0
      p = bytes(name)
      w32(@sym_table + i * 8, p)
      w32(@sym_table + i * 8 + 4, name.bytesize)
      @syms[name] = i
    end

    # --- オブジェクト
    def obj(klass, tt)
      a = alloc(SLOT)
      @objs << a
      w32(a + H_CLASS, klass || 0)
      w32(a + H_FLAGS, TT.fetch(tt))
      a
    end

    def mtable(capa = 16)
      head = alloc(MT_HEAD, 4)
      rows = alloc(capa * MT_ENTRY, 4)
      capa.times { |i| w32(rows + i * MT_ENTRY, MT_EMPTY) }
      w32(head + MT_COUNT, 0)
      w32(head + MT_CAPA, capa)
      w32(head + MT_ROWS, rows)
      head
    end

# iv の表 (インスタンス変数と定数、layout.rb の IV)。行は {シンボル, 値 16 バイト}
def ivtable(capa = 16)
  head = alloc(MT_HEAD, 4)
  rows = alloc(capa * IV_ENTRY, 4)
  capa.times { |i| w32(rows + i * IV_ENTRY, MT_EMPTY) }
  w32(head + MT_COUNT, 0)
  w32(head + MT_CAPA, capa)
  w32(head + MT_ROWS, rows)
  head
end

def iv_set(head, sym, tag, v)
  capa = r32(head + MT_CAPA)
  raise Error, "iv table full" if (r32(head + MT_COUNT) + 1) * 4 > capa * 3
  rows = r32(head + MT_ROWS)
  i = sym & (capa - 1)
  i = (i + 1) & (capa - 1) until [MT_EMPTY, sym].include?(r32(rows + i * IV_ENTRY))
  w32(head + MT_COUNT, r32(head + MT_COUNT) + 1) if r32(rows + i * IV_ENTRY) == MT_EMPTY
  w32(rows + i * IV_ENTRY, sym)
  wval(rows + i * IV_ENTRY + 4, tag, v)
end

    def mt_set(head, sym, val)
      capa = r32(head + MT_CAPA)
      if (r32(head + MT_COUNT) + 1) * 4 > capa * 3 # 詰め率 3/4 を超えたら倍にする
        grow(head, capa * 2)
        capa *= 2
      end
      rows = r32(head + MT_ROWS)
      i = sym & (capa - 1)
      loop do
        s = r32(rows + i * MT_ENTRY)
        if s == MT_EMPTY || s == sym
          w32(head + MT_COUNT, r32(head + MT_COUNT) + 1) if s == MT_EMPTY
          w32(rows + i * MT_ENTRY, sym)
          w32(rows + i * MT_ENTRY + 4, val)
          return
        end
        i = (i + 1) & (capa - 1)
      end
    end

    def grow(head, capa)
      old = r32(head + MT_ROWS)
      ocapa = r32(head + MT_CAPA)
      entries = (0...ocapa).map { |i| [r32(old + i * MT_ENTRY), r32(old + i * MT_ENTRY + 4)] }.reject { |s, _| s == MT_EMPTY }
      rows = alloc(capa * MT_ENTRY, 4)
      capa.times { |i| w32(rows + i * MT_ENTRY, MT_EMPTY) }
      w32(head + MT_ROWS, rows)
      w32(head + MT_CAPA, capa)
      w32(head + MT_COUNT, 0)
      entries.each { |s, v| mt_set(head, s, v) }
    end

    def mt_get(head, sym)
      capa = r32(head + MT_CAPA)
      rows = r32(head + MT_ROWS)
      i = sym & (capa - 1)
      capa.times do
        s = r32(rows + i * MT_ENTRY)
        return nil if s == MT_EMPTY
        return r32(rows + i * MT_ENTRY + 4) if s == sym
        i = (i + 1) & (capa - 1)
      end
      nil
    end

    # --- コアのクラス (mruby の boot_defclass と make_metaclass)
    def build_classes
      @classes = {}
      CORE.each do |name, sup, kind|
        c = obj(nil, kind == :module ? :MODULE : :CLASS)
        w32(c + C_SUPER, sup ? @classes.fetch(sup) : 0)
        w32(c + C_MT, mtable)
        w32(c + C_ROM, mtable)
        w32(c + C_NAME, intern(name))
        w32(c + C_IV, ivtable(name == "Object" ? 128 : 16))
        @classes[name] = c
      end
      # 定数 (Object::Integer ...。mruby の mrb_define_class が Object に置く)
      CORE.each { |name, *| iv_set(r32(@classes["Object"] + C_IV), @syms.fetch(name), TAG_OBJ, @classes[name]) }
      # include (iclass を親との間に挟む。iclass は module の表の見出しを共有する)
      CORE.each { |name, _, _, inc| include_module(@classes[name], @classes.fetch(inc)) if inc }
      CORE_INCLUDES.each { |name, inc| include_module(@classes[name], @classes.fetch(inc)) }
      # クラスの見出しのクラス: クラスはメタクラス、module は Module
      klass = @classes["Class"]
      CORE.each do |name, sup, kind|
        c = @classes[name]
        if kind == :module
          w32(c + H_CLASS, @classes["Module"])
        else
          meta = obj(klass, :SCLASS)
          sup_meta = sup ? r32(@classes[sup] + H_CLASS) : klass
          w32(meta + C_SUPER, sup_meta)
          w32(meta + C_MT, mtable)
          w32(meta + C_ROM, mtable)
          w32(meta + C_IV, ivtable)
          w32(meta + C_OUTER, c) # 付いているクラス (__attached__)
          w32(c + H_CLASS, meta)
        end
      end
    end

    def include_module(c, m)
      ic = obj(m, :ICLASS)
      w32(ic + C_SUPER, r32(c + C_SUPER))
      w32(ic + C_MT, r32(m + C_MT))
      w32(ic + C_ROM, r32(m + C_ROM))
      w32(ic + C_IV, r32(m + C_IV)) # module の iv (定数) を共有する (mruby の ic->iv = m->iv)
      w32(c + C_SUPER, ic)
    end

    def singleton(c)
      cls = r32(c + H_CLASS)
      return cls if (r32(cls + H_FLAGS) & 0xFF) == TT[:SCLASS]
      meta = obj(@classes["Class"], :SCLASS) # module の特異クラス
      w32(meta + C_SUPER, cls)
      w32(meta + C_MT, mtable)
      w32(meta + C_ROM, mtable)
      w32(meta + C_IV, ivtable)
      w32(meta + C_OUTER, c)
      w32(c + H_CLASS, meta)
      meta
    end

    # --- .mrb の irep を読む (mruby の load.c の read_irep_record_1 と同じ並び)。{irep の番地} を作る
    def load_irep(blob, pos)
      base = blob # 像の中の .mrb の先頭の番地
      rec = pos
      nlocals = (@mem.getbyte(rec + 4) << 8) | @mem.getbyte(rec + 5)
      nregs = (@mem.getbyte(rec + 6) << 8) | @mem.getbyte(rec + 7)
      rlen = (@mem.getbyte(rec + 8) << 8) | @mem.getbyte(rec + 9)
      clen = (@mem.getbyte(rec + 10) << 8) | @mem.getbyte(rec + 11)
      ilen = r32(rec + 12)
      iseq = rec + 16
      catch = iseq + ilen
      p = catch + 13 * clen
      plen = (@mem.getbyte(p) << 8) | @mem.getbyte(p + 1)
      p += 2
      pool = alloc([plen, 1].max * VALUE)
      plen.times do |k|
        tt = @mem.getbyte(p)
        p += 1
        case tt
        when 0, 2 # IREP_TT_STR / SSTR
          len = (@mem.getbyte(p) << 8) | @mem.getbyte(p + 1)
          wval(pool + k * VALUE, TAG_UNDEF, (len << 32) | (p + 2))
          p += 2 + len + 1
        when 1 # IREP_TT_INT32
          v = r32(p)
          v -= 1 << 32 if v >= 1 << 31
          wval(pool + k * VALUE, TAG_INT, v)
          p += 4
        when 3 # IREP_TT_INT64
          wval(pool + k * VALUE, TAG_INT, (r32(p) << 32) | r32(p + 4))
          p += 8
        when 5 # IREP_TT_FLOAT (double の IEEE 754 を little endian で 8 バイト、load.c の str_to_double)
          wval(pool + k * VALUE, TAG_FLOAT, @mem.byteslice(p, 8).unpack1("Q<"))
          p += 8
        else raise Error, "pool type #{tt} (bigint) is not supported"
        end
      end
      slen = (@mem.getbyte(p) << 8) | @mem.getbyte(p + 1)
      p += 2
      syms = alloc([slen, 1].max * WORD, 4)
      slen.times do |k|
        len = (@mem.getbyte(p) << 8) | @mem.getbyte(p + 1)
        if len == 0xFFFF # MRB_DUMP_NULL_SYM_LEN: 名前の無いシンボル (バイトは続かない)
          w32(syms + k * WORD, NULL_SYM)
          p += 2
          next
        end
        w32(syms + k * WORD, intern(@mem.byteslice(p + 2, len)))
        p += 2 + len + 1
      end
      ir = alloc(IREP, 4)
      w16(ir + I_NLOCALS, nlocals)
      w16(ir + I_NREGS, nregs)
      w32(ir + I_ILEN, ilen)
      w32(ir + I_ISEQ, iseq)
      w32(ir + I_POOL, pool)
      w32(ir + I_PLEN, plen)
      w32(ir + I_SYMS, syms)
      w32(ir + I_SLEN, slen)
      w32(ir + I_CATCH, catch)
      w32(ir + I_CLEN, clen)
      reps = alloc([rlen, 1].max * WORD, 4)
      w32(ir + I_REPS, reps)
      w32(ir + I_RLEN, rlen)
      rlen.times do |k|
        child, p = load_irep(base, p)
        w32(reps + k * WORD, child)
      end
      [ir, p]
    end

    def irep_top(blob)
      raise Error, "not RITE0400" unless @mem.byteslice(blob, 8) == "RITE0400"
      raise Error, "no IREP section" unless @mem.byteslice(blob + 20, 4) == "IREP"
      load_irep(blob, blob + 32)[0]
    end

    def irep_field(ir, off) = r32(ir + off)
    def irep_sym(ir, i) = r32(r32(ir + I_SYMS) + i * WORD)
    def irep_rep(ir, i) = r32(r32(ir + I_REPS) + i * WORD)
    def sym_name(id) = @syms.key(id)

    def iseq_of(ir) = @mem.byteslice(r32(ir + I_ISEQ), r32(ir + I_ILEN))

    # --- firmware の読み (クラスの本体の def を ROM の表に)
    def new_proc(ir, target)
      pr = obj(@classes["Proc"], :PROC)
      w32(pr + P_BODY, ir)
      w32(pr + P_TCLASS, target)
      w32(pr + P_FLAGS, PROC_IREP)
      pr
    end

    def build_firmware
      blob = bytes(@fw_bin)
      top = irep_top(blob)
      regs = {} # レジスタ → クラスの番地 (CLASS / MODULE の後)
      each_insn(top) do |i|
        case i.name
        when "LOADNIL", "LOADSELF", "RETURN", "RETNIL", "STOP", "NOP"
        when "CLASS", "MODULE"
          name = sym_name(irep_sym(top, i.b))
          regs[i.a] = @classes.fetch(name) { raise Error, "firmware: #{name} is not a core class (add it to Image::CORE)" }
        when "EXEC"
          class_body(regs.fetch(i.a), irep_rep(top, i.b))
        else raise Error, "firmware top level: #{i.name} is not allowed (only class / module bodies)"
        end
      end
    end

    def class_body(c, ir)
      each_insn(ir) do |i|
        case i.name
        when "TDEF"
          mt_set(r32(c + C_ROM), irep_sym(ir, i.b), new_proc(irep_rep(ir, i.c), c))
        when "SDEF" # def self.x (R[a] は LOADSELF)
          meta = singleton(c)
          mt_set(r32(meta + C_ROM), irep_sym(ir, i.b), new_proc(irep_rep(ir, i.c), meta))
        when "ALIAS"
          old = mt_get(r32(c + C_ROM), irep_sym(ir, i.b)) or raise Error, "firmware alias: #{sym_name(irep_sym(ir, i.b))} is not defined yet"
          mt_set(r32(c + C_ROM), irep_sym(ir, i.a), old)
        when "LOADSELF", "LOADNIL", "RETURN", "RETNIL", "NOP"
        else raise Error, "firmware class body: #{i.name} is not allowed"
        end
      end
    end

    def each_insn(ir)
      iseq = iseq_of(ir)
      pc = 0
      while pc < iseq.bytesize
        i = Ops.decode(iseq, pc)
        yield i
        pc = i.next_pc
      end
    end

    # --- 全体
    def build
      w32(0, IMG_MAGIC.unpack1("N"))
      w32(IMG[:version] * WORD, IMG_VERSION)
      @sym_table = alloc(SYM_CAPA * 8, 8)
      prims = mtable(64)
      PRIMS.each_with_index { |n, k| mt_set(prims, intern(n), k) }
      HW_SYMS.each { |n| intern(n) }
      build_classes
      build_firmware
      core = alloc(CORE_TABLE.size * WORD, 4)
      CORE_TABLE.each_with_index { |n, k| w32(core + k * WORD, @classes.fetch(n)) }
      main = obj(@classes["Object"], :OBJECT)
      boot = mt_get(r32(@classes["Object"] + C_ROM), @syms.fetch("__boot") { raise Error, "firmware must define Object#__boot" }) or
             raise Error, "firmware must define Object#__boot"
      progs = alloc([@programs.size, 1].max * 8, 4)
      @programs.each_with_index do |bin, k|
        a = bytes(bin)
        w32(progs + k * 8, a)
        w32(progs + k * 8 + 4, bin.bytesize)
      end
      stack = alloc(STACK_VALUES * VALUE, 16)
      ci = alloc(CI_FRAMES * CI_SIZE, 16)
      mark = alloc(MARK_STACK * WORD, 16)
      roots = alloc([@objs.size, 1].max * WORD, 4)
      @objs.each_with_index { |o, k| w32(roots + k * WORD, o) }
      heap = (@brk + 63) & -64
      heap_end = @heap_size ? [heap + @heap_size, MEM_SIZE].min & -8 : MEM_SIZE
      # ヒープは最初は1つの塊 (回路の hp..hlim)。ブロックの見出しは確保の時に回路が書く
      { free_list: 0, gc_color: 0, roots: roots, nroots: @objs.size, mark_stack: mark, mark_stack_end: mark + MARK_STACK * WORD,
        heap_start: heap, heap_end: heap_end, sym_table: @sym_table, sym_capa: SYM_CAPA, sym_count: @syms.size,
        core_classes: core, main_obj: main, fw_entry: boot, programs: progs, nprograms: @programs.size,
        stack: stack, stack_end: stack + STACK_VALUES * VALUE, prims: prims, ci: ci }.each { |k, v| w32(IMG.fetch(k) * WORD, v) }
      w32(IMG[:sym_count] * WORD, @syms.size)
      @mem
    end
  end
end
