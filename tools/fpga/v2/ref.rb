# v2 のコアの参照 (Ruby コード)。回路がする命令の実行と罠 (設計 §1・§5・§14) を写す。firmware (mruby ソースコード) はこの上で走る。
#
# - 記憶は起動の像 (image.rb) のバイト列。値は 16 バイト (layout.rb)。VM のスタックも記憶の中 (firmware の GC が根として読む)
# - 呼び出し: 特権の primitive の表 (symbol で引く) → メソッドの cache ({クラス, シンボル}) → 外れたら罠 `__trap_lookup(クラス, シンボル)`。
#   罠が Proc を返せばそれを呼び、nil なら引数の前に :名前 を入れて method_missing を引き直す (mruby の vm.c の OP_SEND と同じ順)
# - 回路が持たない命令は罠 `__op_<命令の名前>(a, b, c)`。firmware は `__fpga_reg` / `__fpga_setreg` で罠を起こしたフレームのレジスタを読み書きする
# - コンソールは __fpga_putc のバイト列
require_relative "layout"
require_relative "ops"
require_relative "image"

module FpgaV2
  class Ref
    include Layout
    class Error < StandardError; end
    class Halt < StandardError; end

    INT_MIN = -(1 << 63)
    INT_MAX = (1 << 63) - 1
    MASK64 = (1 << 64) - 1

    # 回路が自分で実行する命令 (ほかは罠)
    HW_OPS = %w[
      NOP MOVE LOADL LOADI8 LOADINEG LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6 LOADI_7 LOADI16 LOADI32
      LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE JMP JMPIF JMPNOT JMPNIL SEND SEND0 SSEND SSEND0 SENDB SSENDB ENTER
      RETURN RETURN_BLK RETNIL RETSELF RETTRUE RETFALSE STOP ADD ADDI SUB SUBI MUL DIV EQ LT LE GT GE ADDILV SUBILV
      GETIDX GETIDX0 SETIDX ARRAY ARRAY2 ARYCAT ARYPUSH
    ].freeze

    # tclass: 定義の入れ物 (mruby の ci->u.target_class)。メソッドは Proc の target_class、EXEC はそのクラス、一番外は Object
    # argc は呼ばれた時の引数の数 (mruby の ci->n。ENTER が読む。罠をはさんでも変わらない)
    Frame = Struct.new(:irep, :pc, :bp, :proc, :mid, :kind, :resume, :dst, :tclass, :vis, :argc, keyword_init: true)

    attr_reader :console, :stats, :steps

    def initialize(image, max_steps: 10_000_000)
      @m = image.dup.force_encoding(Encoding::BINARY)
      @max = max_steps
      @steps = 0
      @console = +"".b
      @stats = Hash.new(0)
      @cache = {}
      h = ->(k) { r32(IMG.fetch(k) * WORD) }
      @heap = h.(:heap_start)
      @heap_end = h.(:heap_end)
      @stack = h.(:stack)
      @stack_end = h.(:stack_end)
      @core = h.(:core_classes)
      @prims = h.(:prims)
      @main = h.(:main_obj)
      @entry = h.(:fw_entry)
      @frames = []
      @object = r32(@main + H_CLASS)
    end

    # 使ったヒープのバイト数 (accept の記録。GC が無い間は確保の合計)
    def heap_used = @heap - r32(IMG.fetch(:heap_start) * WORD)

    # --- 記憶
    def r8(a) = @m.getbyte(a)
    def w8(a, v) = @m.setbyte(a, v & 0xFF)
    def r16(a) = (@m.getbyte(a) << 8) | @m.getbyte(a + 1)
    def r32(a) = (@m.getbyte(a) << 24) | (@m.getbyte(a + 1) << 16) | (@m.getbyte(a + 2) << 8) | @m.getbyte(a + 3)

    def w32(a, v)
      v &= 0xFFFF_FFFF
      @m.setbyte(a, v >> 24)
      @m.setbyte(a + 1, (v >> 16) & 0xFF)
      @m.setbyte(a + 2, (v >> 8) & 0xFF)
      @m.setbyte(a + 3, v & 0xFF)
    end

    def s64(v) = (v &= MASK64) >= 1 << 63 ? v - (1 << 64) : v

    def rv(a)
      tag = r32(a)
      v = (r32(a + 8) << 32) | r32(a + 12)
      [tag, tag == TAG_INT ? s64(v) : v]
    end

    def wv(a, val)
      tag, v = val
      v &= MASK64
      w32(a, tag)
      w32(a + 4, 0)
      w32(a + 8, v >> 32)
      w32(a + 12, v & 0xFFFF_FFFF)
    end

    NIL = [TAG_NIL, 0].freeze
    TRUE_ = [TAG_TRUE, 0].freeze
    FALSE_ = [TAG_FALSE, 0].freeze
    def int(v) = [TAG_INT, v]
    def obj(a) = [TAG_OBJ, a]
    def truthy?(v) = v[0] != TAG_NIL && v[0] != TAG_FALSE

    # --- レジスタ (今のフレームの窓)
    def reg(i) = rv(@stack + (@f.bp + i) * VALUE)

    def setreg(i, v)
      a = @stack + (@f.bp + i) * VALUE
      raise Error, "stack overflow" if a + VALUE > @stack_end
      wv(a, v)
    end

    # --- クラス
    def class_of(v)
      v[0] == TAG_OBJ ? r32(v[1] + H_CLASS) : r32(@core + v[0] * WORD)
    end

    def irep_sym(ir, i) = r32(r32(ir + I_SYMS) + i * WORD)
    def irep_rep(ir, i) = r32(r32(ir + I_REPS) + i * WORD)

    # 表 (メソッド表の形、layout.rb) を引く
    def table_get(head, sym)
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

    def trap_proc(name)
      table_get(r32(@object + C_ROM), sym_id(name)) or raise Error, "firmware has no Object##{name}"
    end

    def sym_id(name)
      @sym_ids ||= {}
      @sym_ids[name] ||= begin
        tab = r32(IMG[:sym_table] * WORD)
        capa = r32(IMG[:sym_capa] * WORD)
        i = Image.sym_hash(name) & (capa - 1)
        loop do
          p = r32(tab + i * 8)
          raise Error, "symbol #{name} is not in the image" if p.zero?
          break i if r32(tab + i * 8 + 4) == name.bytesize && @m.byteslice(p, name.bytesize) == name
          i = (i + 1) & (capa - 1)
        end
      end
    end

    def sym_name(id)
      tab = r32(IMG[:sym_table] * WORD)
      @m.byteslice(r32(tab + id * 8), r32(tab + id * 8 + 4))
    end

    # --- 実行
    def run
      push_call(@entry, obj(@main), kind: :boot, mid: sym_id("__boot"))
      loop do
        raise Error, "step limit #{@max}" if @steps >= @max
        step
      end
    rescue Halt
      @console
    end

    def iseq_byte_reader(ir) = r32(ir + I_ISEQ)

    def fetch
      ir = @f.irep
      base = r32(ir + I_ISEQ)
      len = r32(ir + I_ILEN)
      @iseq_cache ||= {}
      iseq = (@iseq_cache[base] ||= @m.byteslice(base, len))
      Ops.decode(iseq, @f.pc)
    end

    def step
      @steps += 1
      i = fetch
      @pc_next = i.next_pc
      @stats[:insn] += 1
      if HW_OPS.include?(i.name)
        exec(i)
      else
        trap_op(i)
      end
      @f.pc = @pc_next if @f && !@jumped
      @jumped = false
    end

    def jump(target)
      @f.pc = target
      @jumped = true
    end

    def exec(i)
      a = i.a
      b = i.b
      c = i.c
      case i.name
      when "NOP"
      when "MOVE" then setreg(a, reg(b))
      when "LOADL" then setreg(a, pool(b))
      when "LOADI8" then setreg(a, int(b))
      when "LOADINEG" then setreg(a, int(-b))
      when "LOADI__1" then setreg(a, int(-1))
      when /\ALOADI_(\d)\z/ then setreg(a, int(Regexp.last_match(1).to_i))
      when "LOADI16" then setreg(a, int(b >= 0x8000 ? b - 0x10000 : b))
      when "LOADI32" then setreg(a, int(s32((b << 16) | c)))
      when "LOADSYM" then setreg(a, [TAG_SYM, irep_sym(@f.irep, b)])
      when "LOADNIL" then setreg(a, NIL)
      when "LOADSELF" then setreg(a, reg(0))
      when "LOADTRUE" then setreg(a, TRUE_)
      when "LOADFALSE" then setreg(a, FALSE_)
      when "JMP" then jump(@pc_next + s16(a))
      when "JMPIF" then jump(@pc_next + s16(b)) if truthy?(reg(a))
      when "JMPNOT" then jump(@pc_next + s16(b)) unless truthy?(reg(a))
      when "JMPNIL" then jump(@pc_next + s16(b)) if reg(a)[0] == TAG_NIL
      when "SEND", "SSEND", "SENDB", "SSENDB"
        setreg(a, reg(0)) if i.name.start_with?("SS")
        send_op(a, irep_sym(@f.irep, b), c, i.name.end_with?("B"), fcall: i.name.start_with?("SS"))
      when "SEND0", "SSEND0"
        setreg(a, reg(0)) if i.name == "SSEND0"
        send_op(a, irep_sym(@f.irep, b), 0, false, fcall: i.name == "SSEND0")
      when "ENTER" then enter(a)
      when "RETURN" then ret(reg(a))
      when "RETURN_BLK" # ブロックでなければ RETURN と同じ (vm.c: MRB_PROC_ENV_P でない)。ブロックは V2d
        raise Error, "RETURN_BLK in a block is V2d" if @f.kind == :block
        ret(reg(a))
      when "RETNIL" then ret(NIL)
      when "RETSELF" then ret(reg(0))
      when "RETTRUE" then ret(TRUE_)
      when "RETFALSE" then ret(FALSE_)
      when "STOP" then stop
      when "ADD", "SUB", "MUL" then arith(i.name, a)
      when "DIV" then div(a)
      # GETIDX / GETIDX0 / SETIDX: mruby は Array・Hash・String の近道を持つが、見える意味は [] / []= を送るのと同じ
      # (再定義も効く)。v2 は送る。近道は Array#[] などを回路の primitive にすることで得る
      # ARRAY: R[a] = [R[a] .. R[a+b-1]]、ARRAY2: R[a] = [R[b] .. R[b+c-1]] (配列は回路が作る、vm.c の OP_ARRAY)
      when "ARRAY" then setreg(a, alloc_array((0...b).map { |k| reg(a + k) }))
      when "ARRAY2" then setreg(a, alloc_array((0...c).map { |k| reg(b + k) }))
      # ARYCAT: R[a] = R[a] + splat(R[a+1])、ARYPUSH: R[a] に R[a+1..a+b] を足す。新しい配列を作る (R[a] はこの命令の作業の配列なので見える違いは無い)。
      # splat は Array ならその中身、nil なら空 (Array でも nil でもないものの to_a は V2e)
      when "ARYCAT" then setreg(a, alloc_array((reg(a)[0] == TAG_NIL ? [] : ary_values(reg(a)[1])) + splat(reg(a + 1)))) # R[a] が nil なら splat だけ (vm.c)
      when "ARYPUSH" then setreg(a, alloc_array(ary_values(reg(a)[1]) + (1..b).map { |k| reg(a + k) }))
      when "GETIDX" then send_op(a, sym_id("[]"), 1, false)
      when "GETIDX0" then (setreg(a, reg(b)); setreg(a + 1, int(0)); send_op(a, sym_id("[]"), 1, false))
      when "SETIDX" then send_op(a, sym_id("[]="), 2, false)
      when "ADDI" then addi(a, b, :+)
      when "SUBI" then addi(a, b, :-)
      when "ADDILV" then addilv(a, b, c, :+)
      when "SUBILV" then addilv(a, b, c, :-)
      when "EQ", "LT", "LE", "GT", "GE" then compare(i.name, a)
      else raise Error, "unhandled #{i.name}"
      end
    end

    def s16(v) = v >= 0x8000 ? v - 0x10000 : v
    def s32(v) = v >= 1 << 31 ? v - (1 << 32) : v

    def pool(i)
      v = rv(r32(@f.irep + I_POOL) + i * VALUE)
      raise Error, "LOADL of a string pool entry" if v[0] == TAG_UNDEF
      v
    end

    OPSYM = { "ADD" => "+", "SUB" => "-", "MUL" => "*", "DIV" => "/", "EQ" => "==", "LT" => "<", "LE" => "<=", "GT" => ">", "GE" => ">=" }.freeze

    # 整数同士なら回路で (64bit、桁あふれは罠)。ほかはメソッドを送る (mruby の OP_ADD と同じ)
    def arith(name, a)
      x = reg(a)
      y = reg(a + 1)
      if x[0] == TAG_INT && y[0] == TAG_INT
        r = x[1].send(OPSYM[name].to_sym, y[1])
        return overflow(name, a) if r < INT_MIN || r > INT_MAX
        return setreg(a, int(r))
      end
      send_op(a, sym_id(OPSYM[name]), 1, false)
    end

    # DIV: 整数同士は floor の商 (mruby の OP_DIV、int_div)。0 で割ると罠 __op_zerodiv、INT_MIN / -1 は桁あふれ
    def div(a)
      x = reg(a)
      y = reg(a + 1)
      return send_op(a, sym_id("/"), 1, false) unless x[0] == TAG_INT && y[0] == TAG_INT
      return trap_call("__op_zerodiv", [int(a)]) if y[1].zero?
      r = x[1].div(y[1])
      return overflow("DIV", a) if r > INT_MAX
      setreg(a, int(r))
    end

    # ADDI / SUBI: R[a] = R[a] ± b。整数でなければ R[a+1] = b にしてメソッドを送る
    def addi(a, imm, op)
      x = reg(a)
      if x[0] == TAG_INT
        r = x[1].send(op, imm)
        return overflow(op == :+ ? "ADD" : "SUB", a) if r < INT_MIN || r > INT_MAX
        return setreg(a, int(r))
      end
      setreg(a + 1, int(imm))
      send_op(a, sym_id(op.to_s), 1, false)
    end

    # ADDILV / SUBILV (mruby の OP_MATHILV): R[a] = R[a] ± c (a は局所変数の枠)。整数でなければ作業の枠 R[b] から送り、結果を R[a] へ
    def addilv(a, b, imm, op)
      x = reg(a)
      if x[0] == TAG_INT
        r = x[1].send(op, imm)
        return overflow(op == :+ ? "ADD" : "SUB", a) if r < INT_MIN || r > INT_MAX
        return setreg(a, int(r))
      end
      setreg(b, x)
      setreg(b + 1, int(imm))
      setreg(b + 2, NIL)
      dispatch(b, sym_id(op.to_s), 1, @pc_next, dst: a)
    end

    def compare(name, a)
      x = reg(a)
      y = reg(a + 1)
      if x[0] == TAG_INT && y[0] == TAG_INT
        return setreg(a, x[1].send(OPSYM[name].to_sym, y[1]) ? TRUE_ : FALSE_)
      end
      if name == "EQ" && x[0] != TAG_OBJ && x[0] != TAG_FLOAT && y[0] != TAG_OBJ && y[0] != TAG_FLOAT
        return setreg(a, x == y ? TRUE_ : FALSE_) # 即値同士は値で (mruby の OP_EQ の mrb_obj_eq)
      end
      send_op(a, sym_id(OPSYM[name]), 1, false)
    end

    # 桁あふれ: 罠 __op_overflow(a, 演算) (firmware が RangeError を上げる)
    def overflow(name, a)
      @stats[:overflow] += 1
      trap_call("__op_overflow", [int(a), [TAG_SYM, sym_id(OPSYM[name])]])
    end

    # --- 呼び出し
    # SEND 系: c = 引数の数 n | キーワードの数 << 4。n = 15 は R[a+1] の配列を引数に広げる (splat)。fcall は SSEND 系 (self に送る、private も呼べる)
    def send_op(a, sym, c, blk, fcall: false)
      n = c & 0x0F
      raise Error, "keyword arguments (c = #{c}) are not supported yet" unless (c >> 4).zero?
      setreg(a + (n == 15 ? 2 : n + 1), NIL) unless blk
      if n == 15 # 配列を窓に広げる (mruby は ENTER が広げる。見える意味は同じ)
        list = ary_values(reg(a + 1)[1])
        b = reg(a + 2)
        list.each_with_index { |v, k| setreg(a + 1 + k, v) }
        setreg(a + list.size + 1, b)
        n = list.size
        @stats[:splat] += 1
      end
      dispatch(a, sym, n, @pc_next, fcall: fcall)
    end

    # 引いて呼ぶ。ret_pc は呼び出しの後に続ける pc (罠から戻った時も同じ所へ)。dst は結果を置く呼んだ側のレジスタ
    def dispatch(a, sym, n, ret_pc, dst: nil, fcall: false)
      if (prim = table_get(@prims, sym))
        @stats[:prim] += 1
        raise Error, "primitive with dst" if dst
        return prim_call(prim, a, n)
      end
      cls = class_of(reg(a))
      if (e = @cache[[cls, sym]])
        @stats[:mcache_hit] += 1
        return call_entry(e, a, n, sym, ret_pc, dst, fcall)
      end
      @stats[:mcache_miss] += 1
      trap_call("__trap_lookup", [obj(cls), [TAG_SYM, sym]], resume: [:send, a, n, sym, ret_pc, dst, fcall], above: a + n + 2)
    end

    # メソッド表の値 (Proc の番地 | 可視性) を呼ぶ。private は fcall でなければ見つからないのと同じ (mruby の vm.c: NoMethodError)
    def call_entry(e, a, n, sym, ret_pc, dst, fcall)
      vis = e & VIS_MASK
      if vis == VIS_PRIVATE && !fcall
        @stats[:private_denied] += 1
        return missing(a, n, sym, ret_pc, dst)
      end
      call_proc(e & ~VIS_MASK, a, n, sym, ret_pc, dst)
    end

    # 罠: firmware のメソッドを、今の命令のレジスタの窓の上で呼ぶ。self は main。戻ったら resume。
    # 置き場は nregs の後ろ、呼び出しの途中なら その窓 (受け手・引数・ブロック、above) の後ろ (__fpga_sendv の窓は nregs から始まる)
    def trap_call(name, args, resume: nil, above: 0)
      @stats[:trap] += 1
      pr = trap_proc(name)
      base = [r16(@f.irep + I_NREGS), above].max
      setreg(base, obj(@main))
      args.each_with_index { |v, k| setreg(base + 1 + k, v) }
      setreg(base + args.size + 1, NIL)
      push_frame(pr, base, args.size, kind: :trap, mid: sym_id(name), ret_pc: @pc_next, resume: resume || [:advance])
    end

    def call_proc(pr, a, n, mid, ret_pc, dst = nil)
      case r32(pr + P_FLAGS) & 3
      when PROC_PRIM
        raise Error, "primitive procs with dst" if dst
        prim_call(r32(pr + P_BODY), a, n)
      when PROC_IVGET, PROC_IVSET # attr_reader / attr_writer (class.c の attr の C の closure): 罠で iv を読み書きする
        raise Error, "attr with #{n} argument(s)" unless n == ((r32(pr + P_FLAGS) & 3) == PROC_IVGET ? 0 : 1)
        @stats[:attr] += 1
        @pc_next = ret_pc
        args = [reg(a), [TAG_SYM, r32(pr + P_BODY)]] + (n == 1 ? [reg(a + 1)] : [])
        trap_call(n == 1 ? "__op_ivset" : "__op_ivget", args, resume: [:value, dst || a], above: a + n + 2)
      else
        push_frame(pr, a, n, kind: :call, mid: mid, ret_pc: ret_pc, dst: dst)
      end
    end

    # フレームを積む。呼んだ側は ret_pc から続ける。dst は結果を置く呼んだ側のレジスタ (nil は呼ばれた側の R0 = 呼んだ側の R[a])
    # vis は def の既定の可視性 (一番外は private、ほかは public。mruby の MRB_CI_VISIBILITY)
    def push_frame(pr, a, n, kind:, mid:, ret_pc:, resume: nil, dst: nil)
      raise Error, "call depth" if @frames.size >= 512
      @f.pc = ret_pc
      @frames.push(@f)
      tc = r32(pr + P_TCLASS)
      @f = Frame.new(irep: r32(pr + P_BODY), pc: 0, bp: @f.bp + a, proc: pr, mid: mid, kind: kind, resume: resume, dst: dst,
                     tclass: tc, vis: kind == :run ? VIS_PRIVATE : VIS_PUBLIC)
      @f.argc = n
      @jumped = true
      @stats[:call] += 1
    end

    # 最初の呼び出し (起動)
    def push_call(pr, recv, kind:, mid:)
      @f = Frame.new(irep: r32(pr + P_BODY), pc: 0, bp: 0, proc: pr, mid: mid, kind: kind, tclass: r32(pr + P_TCLASS), vis: VIS_PUBLIC)
      setreg(0, recv)
      setreg(1, NIL)
      @f.argc = 0
    end

    # ENTER (mruby の vm_op_enter、aspec: m1 5bit, o 5bit, r 1bit, m2 5bit, k 5bit, kd 1bit, b 1bit)。
    # 必須・省略可能・残り (配列を回路が作る)・後ろの必須・ブロックを回路で並べる。キーワード (k, kd) は罠 __op_enter_kw
    def enter(aspec)
      m1 = (aspec >> 18) & 0x1F
      o = (aspec >> 13) & 0x1F
      r = (aspec >> 12) & 1
      m2 = (aspec >> 7) & 0x1F
      kw = (aspec >> 2) & 0x1F
      kd = (aspec >> 1) & 1
      return trap_call("__op_enter_kw", [int(aspec), int(@f.argc)]) unless (kw | kd).zero?
      argc = @f.argc
      if argc < m1 + m2 || (r.zero? && argc > m1 + o + m2)
        return trap_call("__op_argc", [int(argc), int(m1 + m2), int(r.zero? ? m1 + o + m2 : -1)])
      end
      args = (1..argc).map { |k| reg(k) }
      blk = reg(argc + 1)
      pre = args.shift(m1)
      post = args.pop(m2)
      opt = args.shift([o, args.size].min)
      rest = args
      regs = pre + opt + Array.new(o - opt.size, NIL)
      regs << alloc_array(rest) if r == 1
      regs.concat(post)
      regs.each_with_index { |v, k| setreg(k + 1, v) }
      setreg(regs.size + 1, blk)
      nregs = r16(@f.irep + I_NREGS)
      ((regs.size + 2)...nregs).each { |k| setreg(k, NIL) }
      # 渡された省略可能の数だけ初期値の JMP の表を飛ばす (vm.c: pc += (argc - m1 - m2) * 3、全部なら o * 3)
      @pc_next += opt.size * 3
    end
    
    # 回路が作る配列 (RArray、layout.rb)。枠と中身の領域を1つずつ
    def alloc_array(values)
      ary = alloc(SLOT)
      buf = alloc([values.size, 1].max * VALUE)
      w32(ary + H_CLASS, r32(@core + CORE_ARRAY * WORD))
      w32(ary + H_FLAGS, TT[:ARRAY])
      w32(ary + A_LEN, values.size)
      w32(ary + A_CAPA, [values.size, 1].max)
      w32(ary + A_PTR, buf)
      values.each_with_index { |v, k| wv(buf + k * VALUE, v) }
      @stats[:array_alloc] += 1
      obj(ary)
    end

    def ret(v)
      done = @f
      raise Halt if @frames.empty?
      @f = @frames.pop
      @jumped = true
      if done.kind == :trap
        resume_trap(done, v)
      elsif done.dst
        setreg(done.dst, v)
      else
        wv(@stack + done.bp * VALUE, v) # 呼んだ側の R[a] は呼ばれた側の R0 (同じ場所)
      end
    end

    # 罠から戻った: resume のとおり続ける (呼んだ側の pc は push_frame で ret_pc にしてある)
    def resume_trap(done, v)
      what, a, n, sym, ret_pc, dst, fcall = done.resume || [:advance]
      case what
      when :value # 罠の結果を R[a] へ (attr)
        setreg(a, v)
      when :send # 探索の罠の結果: メソッド表の値 (Integer) か nil
        @pc_next = ret_pc
        return call_entry(v[1], a, n, sym, ret_pc, dst, fcall) if v[0] == TAG_INT
        missing(a, n, sym, ret_pc, dst)
      end
    end
    
    # 見つからない: method_missing(:名前, 引数...)。引数とブロックの枠を1つずらして前に :名前 (mruby の vm.c と同じ)
    def missing(a, n, sym, ret_pc, dst)
      raise Error, "method_missing is not found either (#{sym_name(sym)})" if sym == sym_id("method_missing")
      (n + 1).downto(1) { |k| setreg(a + k + 1, reg(a + k)) }
      setreg(a + 1, [TAG_SYM, sym])
      @stats[:method_missing] += 1
      dispatch(a, sym_id("method_missing"), n + 1, ret_pc, dst: dst, fcall: true)
    end

    def stop
      return ret(NIL) if @f.kind == :run
      raise Halt
    end

    # --- 回路が持たない命令: __op_<名前>(a, b, c)
    def trap_op(i)
      @stats[:"op_#{i.name}"] += 1
      trap_call("__op_#{i.name}", [int(i.a || 0), int(i.b || 0), int(i.c || 0)])
    end

    # --- 特権の primitive (Image::PRIMS の並び)
    def prim_call(k, a, n)
      name = Image::PRIMS.fetch(k)
      args = (1..n).map { |j| reg(a + j) }
      r = case name
          when "__fpga_ld8" then int(r8(args[0][1]))
          when "__fpga_st8" then (w8(args[0][1], args[1][1]); NIL)
          when "__fpga_ld32" then int(r32(args[0][1]))
          when "__fpga_st32" then (w32(args[0][1], args[1][1]); NIL)
          when "__fpga_ldv" then rv(args[0][1])
          when "__fpga_stv" then (wv(args[0][1], args[1]); NIL)
          when "__fpga_addr" then int(args[0][1])
          when "__fpga_obj" then obj(args[0][1])
          when "__fpga_tag" then int(args[0][0])
          when "__fpga_mkval" then [args[0][1], args[1][1]]
          when "__fpga_int" then int(s64(args[0][1])) # 値のビットを Integer に (Float のビットなど)
          when "__fpga_hi" then int((args[0][1] >> 32) & 0xFFFF_FFFF)
          when "__fpga_lo" then int(args[0][1] & 0xFFFF_FFFF)
          when "__fpga_putc" then (@console << (args[0][1] & 0xFF).chr; NIL)
          when "__fpga_alloc" then int(alloc(args[0][1]))
          when "__fpga_mcache_fill" then (@cache[[args[0][1], args[1][1]]] = args[2][1]; NIL)
          when "__fpga_mcache_clear" then (@cache.clear; NIL)
          when "__fpga_mid" then [TAG_SYM, trapped[0].mid] # 罠を起こしたフレームのメソッドの名前 (mruby の ci->mid)
          when "__fpga_proc" then int(trapped[0].proc) # 罠を起こしたフレームの Proc (定数の字句の鎖、super、def の upper)
          when "__fpga_frame_vis" then int(trapped[0].vis) # 罠を起こしたフレームの def の既定の可視性
          when "__fpga_set_caller_vis" then (@frames.last.vis = args[0][1]; NIL) # 今のメソッドを呼んだフレームの既定の可視性 (private / module_function)
          when "__fpga_class_of" then obj(class_of(args[0])) # 回路の class_of (特異クラスと iclass も含む)
          when "__fpga_sendv" then return sendv(args[0], args[1][1], args[2], args[3], args[4], a) # 名前で送る (send / __send__ / public_send)
          when "__fpga_image" then int(r32(args[0][1] * WORD)) # 起動の像の見出しの語
          when "__fpga_reg" then rv(@stack + (trapped[0].bp + args[0][1]) * VALUE) # 罠を起こしたフレームのレジスタ
          when "__fpga_setreg" then (wv(@stack + (trapped[0].bp + args[0][1]) * VALUE, args[1]); NIL)
          when "__fpga_irep" then int(trapped[0].irep)
          when "__fpga_tclass" then obj(trapped[0].tclass) # 罠を起こしたフレームの定義の入れ物
          when "__fpga_and" then int(s64(args[0][1] & args[1][1]))
          when "__fpga_or" then int(s64(args[0][1] | args[1][1]))
          when "__fpga_xor" then int(s64(args[0][1] ^ args[1][1]))
          when "__fpga_shl" then int(s64(args[0][1] << args[1][1]))
          when "__fpga_shr" then int(args[0][1] >> args[1][1])
          when "__fpga_copy" then (@m[args[0][1], args[2][1]] = @m.byteslice(args[1][1], args[2][1]); NIL) # 記憶の写し (dst, src, n)
          when "__fpga_core" then obj(r32(@core + args[0][1] * WORD)) # 組み込みのクラスの表
          when "__fpga_rem" then int(args[0][1].remainder(args[1][1])) # 0 に向けて切った剰余 (C の %、除算器の余り)。0 で割るのは呼ぶ側が調べる
          when "__fpga_halt" then raise Halt
          when "__fpga_run" then return run_irep(args[0][1], args[1], a)
          when "__fpga_invoke" then return invoke(args[0], args[1][1], args[2], args[3] || NIL, args[4], a)
          else raise Error, "primitive #{name} is not implemented"
          end
      setreg(a, r)
    end

    # 一番近い罠のフレームと、その下 (罠を起こした) のフレーム: [起こしたフレーム, 罠のフレーム]
    def trapped
      stack = @frames + [@f]
      k = stack.rindex { |fr| fr.kind == :trap } or raise Error, "not inside a trap"
      [stack[k - 1], stack[k]]
    end

    def alloc(n)
      a = (@heap + 7) & -8
      raise Error, "heap exhausted (GC is V2c)" if a + n > @heap_end
      @heap = a + n
      a
    end

    # __fpga_run(irep, self): プログラムの一番外の irep を、firmware のフレームの上で実行する。戻り値は R[a] へ
    def run_irep(ir, self_, a)
      pr = alloc(SLOT)
      w32(pr + H_CLASS, 0)
      w32(pr + P_BODY, ir)
      w32(pr + P_FLAGS, PROC_IREP)
      w32(pr + P_TCLASS, r32(@core + CORE_OBJECT * WORD)) # 一番外の定義の入れ物は Object
      base = r16(@f.irep + I_NREGS)
      setreg(base, self_)
      setreg(base + 1, NIL)
      push_frame(pr, base, 0, kind: :run, mid: 0, ret_pc: @pc_next, dst: a)
    end

    # __fpga_invoke(recv, proc, args の配列, blk, mid): proc (メソッド表の値でも可、可視性の bit は見ない) を recv で呼ぶ。
    # mid は呼ばれるフレームのメソッドの名前 (super の先も元の名前、mruby の ci->mid)。戻り値は R[a] へ
    def invoke(recv, pr, args, blk, mid, a)
      base = r16(@f.irep + I_NREGS)
      list = window(base, recv, args, blk)
      call_proc(pr & ~VIS_MASK, base, list, mid ? mid[1] : @f.mid, @pc_next, a)
    end

    # __fpga_sendv(recv, sym, args の配列, blk, fcall): 名前で引いて呼ぶ (探索は回路と同じ、fcall なら private も)。戻り値は R[a] へ
    def sendv(recv, sym, args, blk, fcall, a)
      base = r16(@f.irep + I_NREGS)
      n = window(base, recv, args, blk)
      dispatch(base, sym, n, @pc_next, dst: a, fcall: truthy?(fcall || NIL))
    end

    # 今のフレームの窓の上に {recv, 引数..., blk} を並べ、引数の数を返す
    def window(base, recv, args, blk)
      list = args[0] == TAG_OBJ ? ary_values(args[1]) : []
      setreg(base, recv)
      list.each_with_index { |v, k| setreg(base + 1 + k, v) }
      setreg(base + list.size + 1, blk)
      list.size
    end

    def splat(v)
      return [] if v[0] == TAG_NIL
      return ary_values(v[1]) if v[0] == TAG_OBJ && (r32(v[1] + H_FLAGS) & 0xFF) == TT[:ARRAY]
      raise Error, "splat of a non-Array (to_a) is V2e"
    end

    def ary_values(ary)
      len = r32(ary + A_LEN)
      ptr = r32(ary + A_PTR)
      (0...len).map { |k| rv(ptr + k * VALUE) }
    end
  end
end
