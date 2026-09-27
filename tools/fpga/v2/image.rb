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
    CI_FRAMES = 4096 # mrb_context の ci の並びの数 (1 つは layout.rb の CI_SIZE バイト)

    # コアのクラス: [名前, 親, :class / :module]。mruby の C が定義するもの (class.c の mrb_init_class、object.c、numeric.c、error.c の
    # mrb_init_exception ...) と同じ親。mrblib が定義するもの (Comparable、NameError、NoMethodError、StopIteration) と include は mrblib がする
    CORE = [
      ["BasicObject", nil, :class], ["Object", "BasicObject", :class], ["Module", "Object", :class], ["Class", "Module", :class],
      ["Kernel", nil, :module], ["Enumerable", nil, :module],
      ["NilClass", "Object", :class], ["TrueClass", "Object", :class], ["FalseClass", "Object", :class],
      ["Numeric", "Object", :class], ["Integer", "Numeric", :class], ["Float", "Numeric", :class],
      ["Symbol", "Object", :class], ["String", "Object", :class],
      ["Array", "Object", :class], ["Hash", "Object", :class], ["Range", "Object", :class],
      ["Proc", "Object", :class],
      ["Exception", "Object", :class], ["ScriptError", "Exception", :class], ["NotImplementedError", "ScriptError", :class],
      ["StandardError", "Exception", :class], ["RuntimeError", "StandardError", :class], ["FrozenError", "RuntimeError", :class],
      ["ArgumentError", "StandardError", :class], ["LocalJumpError", "StandardError", :class], ["RangeError", "StandardError", :class],
      ["FloatDomainError", "RangeError", :class], ["RegexpError", "StandardError", :class], ["TypeError", "StandardError", :class],
      ["ZeroDivisionError", "StandardError", :class], ["SyntaxError", "ScriptError", :class], ["IndexError", "StandardError", :class],
      ["KeyError", "IndexError", :class], ["NoMatchingPatternError", "StandardError", :class],
      ["SystemStackError", "Exception", :class], ["NoMemoryError", "Exception", :class]
    ].freeze
    # インスタンスの tt (boot_defclass と MRB_SET_INSTANCE_TT をする所: class.c、error.c、string.c、array.c、hash.c、range.c、proc.c、symbol.c、numeric.c、object.c)。
    # ほかのクラスは親から継ぐ (class.c の boot_defclass)
    INSTANCE_TT = {
      "BasicObject" => :OBJECT, "Object" => :OBJECT, "Module" => :MODULE, "Class" => :CLASS, # class.c の mrb_init_class
      "Exception" => :EXCEPTION, "String" => :STRING, "Array" => :ARRAY, "Hash" => :HASH, "Range" => :RANGE, "Proc" => :PROC,
      "Symbol" => :SYMBOL, "Integer" => :INTEGER, "Float" => :FLOAT, "NilClass" => :FALSE, "TrueClass" => :TRUE, "FalseClass" => :FALSE
    }.freeze
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
      __fpga_class_of __fpga_sendv __fpga_ci __fpga_unwind __fpga_unwind_ret
    ].freeze

    # 回路が名前で送るシンボル (演算の落ち先と method_missing。mruby の MRB_OPSYM と同じく presym)
    HW_SYMS = %w[+ - * / == < <= > >= [] []= method_missing].freeze

    attr_reader :mem, :syms, :classes, :top

    def initialize(firmware:, mrblib: nil, programs: [])
      @fw_bin = firmware
      @mrblib = mrblib
      @programs = programs
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
        itt = INSTANCE_TT.key?(name) ? TT.fetch(INSTANCE_TT[name]) : (sup ? (r32(@classes[sup] + H_FLAGS) >> H_FLAGS_SHIFT) & INSTANCE_TT_MASK : 0)
        w32(c + H_FLAGS, r32(c + H_FLAGS) | (itt << H_FLAGS_SHIFT))
        @classes[name] = c
      end
      # 定数 (Object::Integer ...。mruby の mrb_define_class が Object に置く)
      CORE.each { |name, *| iv_set(r32(@classes["Object"] + C_IV), @syms.fetch(name), TAG_OBJ, @classes[name]) }
      # include (iclass を親との間に挟む。iclass は module の表の見出しを共有する)
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
    # firmware のメソッドの Proc (vm.c の vm_define_method と同じく STRICT | SCOPE | CREF)
    def new_proc(ir, target, flags = PROC_METHOD_FLAGS)
      pr = obj(@classes["Proc"], :PROC)
      w32(pr + P_BODY, ir)
      w32(pr + P_TCLASS, target)
      w32(pr + P_FLAGS, PROC_IREP | flags)
      pr
    end

    # Proc#call (proc.c の call_irep と call_proc): 命令 OP_CALL 1 つの irep (nlocals 0、nregs 2) を Proc の ROM の表に置く
    def build_proc_call
      code = alloc(4, 4)
      @mem.setbyte(code, Ops::NAMES.index("CALL"))
      ir = alloc(IREP, 4)
      w16(ir + I_NLOCALS, 0)
      w16(ir + I_NREGS, 2)
      w32(ir + I_ILEN, 1)
      w32(ir + I_ISEQ, code)
      proc = @classes["Proc"]
      m = new_proc(ir, proc, PROC_SCOPE | PROC_STRICT)
      mt_set(r32(proc + C_ROM), intern("call"), m) # proc.c の mrb_init_proc: call と [] に同じメソッド
      mt_set(r32(proc + C_ROM), intern("[]"), m)
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

    INVENTORY = File.expand_path("../../../fpga/v2/inventory.tsv", __dir__)

    # ROM の表の可視性は、mruby の C の定義と同じにする (MRB_MT_PRIVATE、mrb_define_private_method、module_function)。
    # 正本は棚卸しの表 (host の reflection)。表に無い名前 (firmware の helper) は public
    def self.visibility
      @visibility ||= File.readlines(INVENTORY, chomp: true).reject { |l| l.start_with?("#") }.to_h do |l|
        kind, owner, name = l.split("\t")
        sing = %w[sing spriv].include?(kind)
        [[owner, sing, name], { "priv" => VIS_PRIVATE, "spriv" => VIS_PRIVATE, "prot" => VIS_PROTECTED }.fetch(kind, VIS_PUBLIC)]
      end
    end

    def rom_vis(c, sym, sing)
      Image.visibility.fetch([@classes.key(c), sing, sym_name(sym)], VIS_PUBLIC)
    end

    def class_body(c, ir)
      each_insn(ir) do |i|
        case i.name
        when "TDEF"
          sym = irep_sym(ir, i.b)
          mt_set(r32(c + C_ROM), sym, new_proc(irep_rep(ir, i.c), c) | rom_vis(c, sym, false))
        when "SDEF" # def self.x (R[a] は LOADSELF)
          meta = singleton(c)
          sym = irep_sym(ir, i.b)
          mt_set(r32(meta + C_ROM), sym, new_proc(irep_rep(ir, i.c), meta) | rom_vis(c, sym, true))
        when "ALIAS"
          old = mt_get(r32(c + C_ROM), irep_sym(ir, i.b)) or raise Error, "firmware alias: #{sym_name(irep_sym(ir, i.b))} is not defined yet"
          # 同じ C の関数を別の名前で置く ROM の行は、その名前の可視性を持つ (hash.c の initialize_copy は private、replace は public)
          mt_set(r32(c + C_ROM), irep_sym(ir, i.a), (old & ~VIS_MASK) | rom_vis(c, irep_sym(ir, i.a), false))
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
      w32(IMG[:magic] * WORD, IMG_MAGIC.unpack1("N"))
      @sym_table = alloc(SYM_CAPA * 8, 8)
      prims = mtable(64)
      PRIMS.each_with_index { |n, k| mt_set(prims, intern(n), k) }
      HW_SYMS.each { |n| intern(n) }
      build_classes
      build_firmware
      build_proc_call
      core = alloc(CORE_TABLE.size * WORD, 4)
      CORE_TABLE.each_with_index { |n, k| w32(core + k * WORD, @classes.fetch(n)) }
      main = obj(@classes["Object"], :OBJECT)
      boot = mt_get(r32(@classes["Object"] + C_ROM), @syms.fetch("__fpga_boot") { raise Error, "firmware must define Object#__fpga_boot" }) or
             raise Error, "firmware must define Object#__fpga_boot"
      progs = alloc([@programs.size, 1].max * 8, 4)
      @programs.each_with_index do |bin, k|
        a = bytes(bin)
        w32(progs + k * 8, a)
        w32(progs + k * 8 + 4, bin.bytesize)
      end
      mrblib = @mrblib ? bytes(@mrblib) : 0 # mruby の mrblib/*.rb を 1 つの .mrb にしたもの (起動の時に mrb_init_mrblib が読む)
      stack = alloc(STACK_VALUES * VALUE, 16)
      cis = alloc(CI_FRAMES * CI_SIZE, 16)
      ctx = alloc(CTX_SIZE, 16) # mrb_context (root_c)
      w32(ctx + CTX_STBASE, stack)
      w32(ctx + CTX_STEND, stack + STACK_VALUES * VALUE)
      w32(ctx + CTX_CIBASE, cis)
      w32(ctx + CTX_CI, cis)
      w32(ctx + CTX_CIEND, cis + CI_FRAMES * CI_SIZE)
      globals = ivtable(64) # mrb_state.globals (大域変数の表、D06 の形)
      heap = (@brk + 63) & -64
      state = {
        c: ctx, root_c: ctx, globals: globals, exc: 0, top_self: main,
        object_class: "Object", class_class: "Class", module_class: "Module", proc_class: "Proc", string_class: "String",
        array_class: "Array", hash_class: "Hash", range_class: "Range", float_class: "Float", integer_class: "Integer",
        true_class: "TrueClass", false_class: "FalseClass", nil_class: "NilClass", symbol_class: "Symbol", kernel_module: "Kernel",
        symidx: @syms.size, symtbl: @sym_table, symcapa: SYM_CAPA, eException_class: "Exception", eStandardError_class: "StandardError",
        heap_start: heap, heap_end: MEM_SIZE, core_classes: core, fw_entry: boot, programs: progs, nprograms: @programs.size,
        prims: prims, mrblib: mrblib, version: IMG_VERSION
      }
      state.each { |k, v| w32(IMG.fetch(k) * WORD, v.is_a?(String) ? @classes.fetch(v) : v) }
      @mem
    end
  end
end
