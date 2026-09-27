# v2 のコアの参照 (Ruby コード)。回路がする命令の実行と罠 (設計 §1・§5・§14) を写す。firmware (mruby ソースコード) はこの上で走る。
#
# - 記憶は起動の像 (image.rb) のバイト列。値は 16 バイト (layout.rb)。VM のスタックも記憶の中 (firmware の GC が根として読む)
# - 呼び出し: 特権の primitive の表 (symbol で引く) → メソッドの cache ({クラス, シンボル}) → 外れたら罠 `__fpga_trap_lookup(クラス, シンボル)`。
#   罠が Proc を返せばそれを呼び、nil なら引数の前に :名前 を入れて method_missing を引き直す (mruby の vm.c の OP_SEND と同じ順)
# - 回路が持たない命令は罠 `__fpga_op_<命令の名前>(a, b, c)`。firmware は `__fpga_reg` / `__fpga_setreg` で罠を起こしたフレームのレジスタを読み書きする
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
      GETIDX GETIDX0 SETIDX ARRAY ARRAY2 ARYCAT ARYPUSH GETUPVAR SETUPVAR BLKPUSH CALL BLKCALL
    ].freeze

    # フレーム = 記憶の中の mrb_callinfo (layout.rb の CI_*、計画 S2b)。Ci はその番地を読み書きする窓で、回路の ci のレジスタに当たる。
    # フレームの間変わらない欄 (proc、irep、窓の先頭) だけを持ち (cache)、ほかは記憶を読み書きする
    # - tclass: 定義の入れ物 (ci->u.target_class)。メソッドは Proc の target_class、EXEC はそのクラス、一番外は Object
    # - argc: 呼ばれた時の引数の数 (ci->n と延長の argc、D12。ENTER が読む。罠をはさんでも変わらない)
    # - kind / resume / dst: 罠の続き (延長の語、D11)
    class Ci
      include Layout
      attr_reader :addr, :proc, :irep, :bp

      def initialize(ref, addr)
        @r = ref
        @addr = addr
        @proc = ref.r32(addr + CI_PROC)
        @irep = ref.r32(@proc + P_BODY)
        @bp = (ref.r32(addr + CI_STACK) - ref.stbase) / VALUE
      end

      def pc = @r.r32(@addr + CI_PC) - @r.r32(@irep + I_ISEQ)
      def pc=(v)
        @r.w32(@addr + CI_PC, @r.r32(@irep + I_ISEQ) + v)
      end
      def mid = @r.r32(@addr + CI_MID)
      def tclass
        u = @r.r32(@addr + CI_U)
        @r.env?(u) ? @r.r32(u + H_CLASS) : u
      end
      def argc = @r.r32(@addr + CI_ARGC)

      def argc=(n)
        c = n & CALL_ARGS
        @r.w8(@addr + CI_N, [c, 15].min | ((n & CALL_KW).zero? ? 0 : CI_KW_BIT))
        @r.w32(@addr + CI_ARGC, c)
      end

      def kw? = (@r.r8(@addr + CI_N) & CI_KW_BIT) != 0

      # 可視性 0 public、1 private、2 protected、3 module_function (記憶の中は mruby の bit: private | MRB_CI_MODFUNC)
      def vis
        v = @r.r8(@addr + CI_VIS)
        (v & CI_MODFUNC_BIT).zero? ? v & 3 : 3
      end

      def vis=(v)
        keep = @r.r8(@addr + CI_VIS) & ~(3 | CI_MODFUNC_BIT) # VISIBILITY_BREAK と GIVEN_CLASS の印は残す
        @r.w8(@addr + CI_VIS, keep | (v == 3 ? VIS_PRIVATE | CI_MODFUNC_BIT : v))
      end

      def kind
        case @r.r8(@addr + CI_CONT)
        when CONT_ADVANCE, CONT_SEND, CONT_VALUE, CONT_KWSEND then :trap
        when CONT_BOOT then :boot
        when CONT_RUN then :run
        else :call
        end
      end

      def dst
        d = @r.r32(@addr + CI_CDST)
        d.zero? ? nil : d - 1
      end

      def resume
        case @r.r8(@addr + CI_CONT)
        when CONT_SEND
          [:send, @r.r32(@addr + CI_CA), @r.r32(@addr + CI_CN), @r.r32(@addr + CI_CSYM), @r.r32(@addr + CI_CRET), dst,
           @r.r32(@addr + CI_CFCALL) == 1]
        when CONT_VALUE then [:value, @r.r32(@addr + CI_CA)]
        when CONT_KWSEND
          [:kwsend, @r.r32(@addr + CI_CA), @r.r32(@addr + CI_CN), @r.r32(@addr + CI_CSYM), @r.r32(@addr + CI_CRET), nil,
           @r.r32(@addr + CI_CFCALL) == 1]
        else [:advance]
        end
      end
    end

    CONT_OF = { advance: CONT_ADVANCE, send: CONT_SEND, value: CONT_VALUE, kwsend: CONT_KWSEND }.freeze
    # 呼び出しの引数の数 n の中の印: CALL_KW はキーワードの Hash が引数の後ろにある (ci->kw)。窓は受け手、引数、kdict、ブロック
    CALL_ARGS = 0xFF
    CALL_KW = 0x100

    attr_reader :console, :stats, :steps, :stbase

    def initialize(image, max_steps: 10_000_000)
      @m = image.dup.force_encoding(Encoding::BINARY)
      @max = max_steps
      @steps = 0
      @console = +"".b
      @stats = Hash.new(0)
      @cache = {}
      h = ->(k) { r32(IMG.fetch(k) * WORD) }
      # 回路のレジスタに当たるもの (mrb_state と mrb_context から起動の時に読む定数の番地と、ヒープの bump の位置)
      @heap = h.(:heap_start)
      @heap_end = h.(:heap_end)
      @ctx = h.(:c)
      @stbase = r32(@ctx + CTX_STBASE)
      @stend = r32(@ctx + CTX_STEND)
      @core = h.(:core_classes)
      @prims = h.(:prims)
      @main = h.(:top_self)
      @entry = h.(:fw_entry)
      @object = h.(:object_class)
      @f = nil
    end

    # ref の CRuby 側に持つもの (計画 S2b: 回路のレジスタ・cache・定数の番地だけ。機械の状態は記憶の中)。ref_test が確かめる
    CRUBY_STATE = %i[
      @m @max @steps @console @stats @cache @heap @heap_end @ctx @stbase @stend @core @prims @main @entry @object @f
      @sym_ids @iseq_cache @pc_next @jumped
    ].freeze

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
    def reg(i) = rv(@stbase + (@f.bp + i) * VALUE)

    def setreg(i, v)
      a = @stbase + (@f.bp + i) * VALUE
      raise Error, "stack overflow" if a + VALUE > @stend
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
        tab = r32(IMG[:symtbl] * WORD)
        capa = r32(IMG[:symcapa] * WORD)
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
      tab = r32(IMG[:symtbl] * WORD)
      @m.byteslice(r32(tab + id * 8), r32(tab + id * 8 + 4))
    end

    # --- 実行
    def run
      push_call(@entry, obj(@main), kind: :boot, mid: sym_id("__fpga_boot"))
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
      when "RETURN" then return_op(reg(a))
      when "RETURN_BLK" # env のある strict でないブロックは罠 (vm.c の OP_RETURN_BLK)。ほかは RETURN と同じ
        f = r32(@f.proc + P_FLAGS)
        return trap_op(i) if (f & PROC_ENVSET) != 0 && (f & PROC_STRICT).zero?
        return_op(reg(a))
      when "RETNIL" then return_op(NIL)
      when "RETSELF" then return_op(reg(0))
      when "RETTRUE" then return_op(TRUE_)
      when "RETFALSE" then return_op(FALSE_)
      when "STOP" then stop
      when "ADD", "SUB", "MUL" then arith(i.name, a)
      when "DIV" then div(a)
      # GETIDX / GETIDX0 / SETIDX: mruby は Array・Hash・String の近道を持つが、見える意味は [] / []= を送るのと同じ
      # (再定義も効く)。v2 は送る。近道は Array#[] などを回路の primitive にすることで得る
      # ARRAY: R[a] = [R[a] .. R[a+b-1]]、ARRAY2: R[a] = [R[b] .. R[b+c-1]] (配列は回路が作る、vm.c の OP_ARRAY)
      when "ARRAY" then setreg(a, alloc_array((0...b).map { |k| reg(a + k) }))
      when "ARRAY2" then setreg(a, alloc_array((0...c).map { |k| reg(b + k) }))
      # ARYCAT (vm.c): R[a] が nil なら splat(R[a+1])、そうでなければ R[a] にその場で足す。ARYPUSH: R[a] にその場で R[a+1..a+b] を足す。
      # 回路は Array 同士だけ。splat が to_a を送る時 (mrb_ary_splat) と R[a] が Array でない時 (mrb_ensure_array_type) は罠
      when "ARYCAT" then arycat(i, a)
      when "ARYPUSH" then arypush(i, a, b)
      when "GETIDX" then send_op(a, sym_id("[]"), 1, false)
      when "GETIDX0" then (setreg(a, reg(b)); setreg(a + 1, int(0)); send_op(a, sym_id("[]"), 1, false))
      when "SETIDX" then send_op(a, sym_id("[]="), 2, false)
      when "ADDI" then addi(a, b, :+)
      when "SUBI" then addi(a, b, :-)
      when "ADDILV" then addilv(a, b, c, :+)
      when "SUBILV" then addilv(a, b, c, :-)
      when "EQ", "LT", "LE", "GT", "GE" then compare(i.name, a)
      when "GETUPVAR" then getupvar(a, b, c)
      when "SETUPVAR" then setupvar(a, b, c)
      when "BLKPUSH" then blkpush(i, a, b)
      when "CALL" then vm_call_proc(reg(0)[1], @f.argc + 2) # ci_bidx(ci) + 1
      when "BLKCALL" then blkcall(i, a, b)
      else raise Error, "unhandled #{i.name}"
      end
    end

    def s16(v) = v >= 0x8000 ? v - 0x10000 : v
    def s32(v) = v >= 1 << 31 ? v - (1 << 32) : v

    def pool(i)
      v = rv(r32(@f.irep + I_POOL) + i * VALUE)
      v[0] == TAG_UNDEF ? NIL : v # 数でない pool (文字列) は nil (vm.c の OP_LOADL の default)
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

    # DIV: 整数同士は floor の商 (mruby の OP_DIV、int_div)。0 で割ると罠 __fpga_op_zerodiv、INT_MIN / -1 は桁あふれ
    def div(a)
      x = reg(a)
      y = reg(a + 1)
      return send_op(a, sym_id("/"), 1, false) unless x[0] == TAG_INT && y[0] == TAG_INT
      return trap_call("__fpga_op_zerodiv", [int(a)]) if y[1].zero?
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

    # 桁あふれ: 罠 __fpga_op_overflow(a, 演算) (firmware が RangeError を上げる)
    def overflow(name, a)
      @stats[:overflow] += 1
      trap_call("__fpga_op_overflow", [int(a), [TAG_SYM, sym_id(OPSYM[name])]])
    end

    # --- 呼び出し
    # SEND 系: c = 引数の数 n | キーワードの数 << 4。n = 15 は R[a+1] の配列を引数に広げる (splat)。fcall は SSEND 系 (self に送る、private も呼べる)
    def send_op(a, sym, c, blk, fcall: false)
      n = c & 0x0F
      nk = (c >> 4) & 0x0F
      if nk.positive? && nk < 15 # キーワードを Hash にまとめる (vm.c の hash_new_from_regs、確保があるので罠)
        return trap_call("__fpga_op_kwpack", [int(a), int(n), int(nk), blk ? TRUE_ : FALSE_],
                         resume: [:kwsend, a, n, sym, @pc_next, nil, fcall], above: a + (n == 15 ? 1 : n) + nk * 2 + 2)
      end
      send_kw(a, sym, n, nk == 15, blk, fcall, @pc_next)
    end

    # SEND の本体 (kw ならキーワードの Hash は引数の後ろ)。n = 15 は配列を窓に広げる (mruby は ENTER が広げる、D12)
    def send_kw(a, sym, n, kw, blk, fcall, ret_pc)
      kn = kw ? 1 : 0
      setreg(a + (n == 15 ? 1 : n) + kn + 1, NIL) unless blk
      if n == 15
        list = ary_values(reg(a + 1)[1])
        kd = reg(a + 2)
        b = reg(a + 2 + kn)
        list.each_with_index { |v, k| setreg(a + 1 + k, v) }
        setreg(a + list.size + 1, kd) if kw
        setreg(a + list.size + kn + 1, b)
        n = list.size
        @stats[:splat] += 1
      end
      dispatch(a, sym, n | (kw ? CALL_KW : 0), ret_pc, fcall: fcall)
    end

    # 窓の中の引数の枠の数 (キーワードの Hash も数える)
    def wlen(n) = (n & CALL_ARGS) + ((n & CALL_KW).zero? ? 0 : 1)

    # 引いて呼ぶ。ret_pc は呼び出しの後に続ける pc (罠から戻った時も同じ所へ)。dst は結果を置く呼んだ側のレジスタ
    def dispatch(a, sym, n, ret_pc, dst: nil, fcall: false)
      if (prim = table_get(@prims, sym))
        @stats[:prim] += 1
        raise Error, "primitive with dst" if dst
        return prim_call(prim, a, n & CALL_ARGS)
      end
      cls = class_of(reg(a))
      if (e = @cache[[cls, sym]]) # {メソッド表の値, 見つかったクラス} (vm.c の mrb_vm_find_method の *cp、mrb_cache_entry の c0)
        @stats[:mcache_hit] += 1
        return call_entry(e[0], a, n, sym, ret_pc, dst, fcall, e[1])
      end
      @stats[:mcache_miss] += 1
      trap_call("__fpga_trap_lookup", [obj(cls), [TAG_SYM, sym]], resume: [:send, a, n, sym, ret_pc, dst, fcall], above: a + wlen(n) + 2)
    end

    # メソッド表の値 (Proc の番地 | 可視性) を呼ぶ。private は fcall でなければ見つからないのと同じ (mruby の vm.c: NoMethodError)
    # found は見つかったクラス (呼ばれるフレームの ci->u.target_class、vm.c の L_SENDB_SYM)
    def call_entry(e, a, n, sym, ret_pc, dst, fcall, found = nil)
      vis = e & VIS_MASK
      if vis == VIS_PRIVATE && !fcall
        @stats[:private_denied] += 1
        return missing(a, n, sym, ret_pc, dst)
      end
      call_proc(e & ~VIS_MASK, a, n, sym, ret_pc, dst, found)
    end

    # 罠: firmware のメソッドを、今の命令のレジスタの窓の上で呼ぶ。self は main。戻ったら resume。
    # 置き場は nregs の 1 つ後ろ、呼び出しの途中なら その窓 (受け手・引数・ブロック、above) の後ろ (__fpga_sendv の窓は nregs から始まる)。
    # 1 つ空けるのは、mruby-compiler の begin/rescue/ensure (codegen.c の OP_EXCEPT の idx) が nregs に数えない R[nregs] を使うため。
    # mruby の C の関数 (罠の写し元) は VM のスタックを使わないので、その R[nregs] を壊さない (D11)
    def trap_call(name, args, resume: nil, above: 0)
      @stats[:trap] += 1
      pr = trap_proc(name)
      base = [r16(@f.irep + I_NREGS) + 1, above].max
      setreg(base, obj(@main))
      args.each_with_index { |v, k| setreg(base + 1 + k, v) }
      setreg(base + args.size + 1, NIL)
      push_frame(pr, base, args.size, kind: :trap, mid: sym_id(name), ret_pc: @pc_next, resume: resume || [:advance])
    end

    def call_proc(pr, a, n, mid, ret_pc, dst = nil, found = nil)
      case r32(pr + P_FLAGS) & 3
      when PROC_PRIM
        raise Error, "primitive procs with dst" if dst
        prim_call(r32(pr + P_BODY), a, n & CALL_ARGS)
      when PROC_IVGET, PROC_IVSET # attr_reader / attr_writer (class.c の attr の C の closure): 罠で iv を読み書きする
        @pc_next = ret_pc
        want = (r32(pr + P_FLAGS) & 3) == PROC_IVGET ? 0 : 1 # reader は MRB_PROC_NOARG、writer は mrb_get_arg1
        return trap_call("__fpga_raise_argnum", [int(wlen(n)), int(want), int(want)], above: a + wlen(n) + 2) unless wlen(n) == want
        @stats[:attr] += 1
        args = [reg(a), [TAG_SYM, r32(pr + P_BODY)]] + (n == 1 ? [reg(a + 1)] : [])
        trap_call(n == 1 ? "__fpga_op_ivset" : "__fpga_op_ivget", args, resume: [:value, dst || a], above: a + n + 2)
      else
        push_frame(pr, a, n, kind: :call, mid: mid, ret_pc: ret_pc, dst: dst, tclass: found)
        b = rv(@stbase + (@f.bp + wlen(n) + 1) * VALUE)
        w32(@f.addr + CI_BLK, b[1]) if b[0] == TAG_OBJ && (r32(b[1] + H_FLAGS) & 0xFF) == TT[:PROC]
      end
    end

    # フレームを積む。呼んだ側は ret_pc から続ける。dst は結果を置く呼んだ側のレジスタ (nil は呼ばれた側の R0 = 呼んだ側の R[a])
    # vis は def の既定の可視性 (一番外は private、ほかは public。mruby の MRB_CI_VISIBILITY)
    def push_frame(pr, a, n, kind:, mid:, ret_pc:, resume: nil, dst: nil, tclass: nil)
      ci = @f.addr + CI_SIZE
      # vm.c の cipush: ci の数が MRB_CALL_LEVEL_MAX に届いたら mrb->stack_err を上げる (罠は上げるための余りの枠を使う)
      # firmware (像の中の Proc) のフレームからの呼び出しは数えない (上げる途中の firmware が同じ罠に入らないため)
      if kind != :trap && (ci - r32(@ctx + CTX_CIBASE)) / CI_SIZE >= MRB_CALL_LEVEL_MAX && @f.proc >= r32(IMG.fetch(:heap_start) * WORD)
        @pc_next = ret_pc
        return trap_call("__fpga_op_stack_err", [], above: a + wlen(n) + 2)
      end
      raise Error, "call depth" if ci + CI_SIZE > r32(@ctx + CTX_CIEND)
      @f.pc = ret_pc
      write_ci(ci, pr, @stbase + (@f.bp + a) * VALUE, mid, kind, resume, dst, n, tclass)
      @jumped = true
      @stats[:call] += 1
    end

    # mrb_callinfo を 1 つ書いて今のフレームにする (ctx->ci も)
    def write_ci(ci, pr, stack, mid, kind, resume, dst, n, tclass = nil)
      @m[ci, CI_SIZE] = ("\x00" * CI_SIZE).b
      w8(ci + CI_CCI, kind == :call ? CINFO_NONE : CINFO_DIRECT)
      w32(ci + CI_MID, mid)
      w32(ci + CI_PROC, pr)
      w32(ci + CI_STACK, stack)
      w32(ci + CI_U, tclass || r32(pr + P_TCLASS))
      cont = { trap: CONT_OF.fetch((resume || [:advance])[0]), boot: CONT_BOOT, run: CONT_RUN }.fetch(kind, CONT_NONE)
      w8(ci + CI_CONT, cont)
      w32(ci + CI_CDST, dst ? dst + 1 : 0)
      if resume && resume[0] != :advance
        _, ca, cn, csym, cret, _, fcall = resume
        w32(ci + CI_CA, ca)
        w32(ci + CI_CN, cn || 0)
        w32(ci + CI_CSYM, csym || 0)
        w32(ci + CI_CRET, cret || 0)
        w32(ci + CI_CFCALL, fcall ? 1 : 0)
        w32(ci + CI_CDST, resume[5] ? resume[5] + 1 : 0) if resume[0] == :send
      end
      w32(@ctx + CTX_CI, ci)
      @f = Ci.new(self, ci)
      @f.pc = 0
      @f.vis = kind == :run ? VIS_PRIVATE : VIS_PUBLIC
      @f.argc = n
    end

    # 最初の呼び出し (起動)
    def push_call(pr, recv, kind:, mid:)
      write_ci(r32(@ctx + CTX_CIBASE), pr, @stbase, mid, kind, nil, nil, 0)
      setreg(0, recv)
      setreg(1, NIL)
    end

    # ENTER (mruby の vm_op_enter、aspec: m1 5bit, o 5bit, r 1bit, m2 5bit, k 5bit, kd 1bit, b 1bit)。
    # 必須・省略可能・残り (配列を回路が作る)・後ろの必須・ブロックを回路で並べる。キーワード (k, kd) は罠 __fpga_op_enter_kw
    def enter(aspec)
      m1 = (aspec >> 18) & 0x1F
      o = (aspec >> 13) & 0x1F
      r = (aspec >> 12) & 1
      m2 = (aspec >> 7) & 0x1F
      kw = (aspec >> 2) & 0x1F
      kd = (aspec >> 1) & 1
      noblock = (aspec >> 23) & 1 # `&nil` (MRB_ASPEC_NOBLOCK): ブロックを渡されたら ArgumentError
      # 罠の窓は、渡された引数 (nregs より多いことがある) とキーワードの Hash とブロックの後ろから
      above = @f.argc + (@f.kw? ? 1 : 0) + 2
      return trap_call("__fpga_op_enter_kw", [int(aspec), int(@f.argc)], above: above) unless (kw | kd | noblock).zero? && !@f.kw?
      argc = @f.argc
      len = m1 + o + r + m2
      args = (1..argc).map { |k| reg(k) }
      blk = reg(argc + 1)
      if (r32(@f.proc + P_FLAGS) & PROC_STRICT) != 0
        if argc < m1 + m2 || (r.zero? && argc > len)
          return trap_call("__fpga_op_argc", [int(argc), int(m1 + m2), int(r.zero? ? m1 + o + m2 : -1)], above: above)
        end
      elsif len > 1 && argc == 1 && array?(args[0]) # strict でない Proc (ブロック) は 1 つの配列を広げる
        args = ary_values(args[0][1])
        argc = args.size
      end
      regs = Array.new(len, NIL)
      if argc < len
        mlen = m2
        mlen = m1 < argc ? argc - m1 : 0 if argc < m1 + m2
        args[0, argc - mlen].each_with_index { |v, k| regs[k] = v } # m1 と o の前から
        args[argc - mlen, mlen].each_with_index { |v, k| regs[len - m2 + k] = v } # 後ろの必須
        regs[m1 + o] = alloc_array([]) if r == 1
        @pc_next += (argc - m1 - m2) * 3 if o.positive? && argc > m1 + m2 # 渡された省略可能の数だけ初期値の JMP の表を飛ばす
      else
        rnum = argc - m1 - o - m2
        args[0, m1 + o].each_with_index { |v, k| regs[k] = v }
        regs[m1 + o] = alloc_array(args[m1 + o, rnum]) if r == 1
        args[m1 + o + rnum, m2].each_with_index { |v, k| regs[m1 + o + r + k] = v } if m2.positive?
        @pc_next += o * 3
      end
      regs.each_with_index { |v, k| setreg(k + 1, v) }
      setreg(len + 1, blk)
      # blk の後ろを nlocals まで nil (stack_clear)。ci->n は引数の枠の数 (len、15 で飽和)
      nlocals = r16(@f.irep + I_NLOCALS)
      ((len + 2)...nlocals).each { |k| setreg(k, NIL) }
      @f.argc = len
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

    # irep に catch handler があるか (vm.c の irep->clen > 0)
    def catch? = r32(@f.irep + I_CLEN).positive?

    # RETURN 系 (vm.c の L_RETURN): catch があれば ensure を見るので罠 __fpga_op_return(v)、無ければ回路で戻る
    def return_op(v)
      return trap_call("__fpga_op_return", [v]) if catch?

      ret(v)
    end

    # vm.c の cipop: env を unshare し、渡したブロック (ci->blk) が strict でなく、その env が 1 つ下の ci の env なら ORPHAN にする
    def cipop(ci)
      env_unshare(r32(ci + CI_U))
      b = r32(ci + CI_BLK)
      return if b.zero?

      bf = r32(b + P_FLAGS)
      below = r32(ci - CI_SIZE + CI_U)
      if (bf & PROC_STRICT).zero? && (bf & PROC_ENVSET) != 0 && env?(below) && r32(b + P_ENV) == below
        w32(b + P_FLAGS, bf | PROC_ORPHAN)
      end
    end

    def ret(v)
      done = @f
      cipop(done.addr)
      raise Halt if done.addr == r32(@ctx + CTX_CIBASE)
      w32(@ctx + CTX_CI, done.addr - CI_SIZE)
      @f = Ci.new(self, done.addr - CI_SIZE)
      @jumped = true
      if done.kind == :trap
        resume_trap(done, v)
      elsif done.dst
        setreg(done.dst, v)
      else
        wv(@stbase + done.bp * VALUE, v) # 呼んだ側の R[a] は呼ばれた側の R0 (同じ場所)
      end
    end

    # 罠から戻った: resume のとおり続ける (呼んだ側の pc は push_frame で ret_pc にしてある)
    def resume_trap(done, v)
      what, a, n, sym, ret_pc, dst, fcall = done.resume || [:advance]
      case what
      when :value # 罠の結果を R[a] へ (attr)
        setreg(a, v)
      when :kwsend # キーワードを Hash にまとめた後の SEND (ブロックは firmware が kdict の後ろに置いた)
        @pc_next = ret_pc
        return send_kw(a, sym, n, true, true, fcall, ret_pc)
      when :send # 探索の罠の結果: メソッド表の値 (Integer) か nil
        @pc_next = ret_pc
        return call_entry(v[1], a, n, sym, ret_pc, dst, fcall, @cache[[class_of(reg(a)), sym]]&.last) if v[0] == TAG_INT
        missing(a, n, sym, ret_pc, dst)
      end
    end
    
    # 見つからない: method_missing(:名前, 引数...)。引数とブロックの枠を1つずらして前に :名前 (mruby の vm.c と同じ)
    def missing(a, n, sym, ret_pc, dst)
      raise Error, "method_missing is not found either (#{sym_name(sym)})" if sym == sym_id("method_missing")
      (wlen(n) + 1).downto(1) { |k| setreg(a + k + 1, reg(a + k)) }
      setreg(a + 1, [TAG_SYM, sym])
      @stats[:method_missing] += 1
      dispatch(a, sym_id("method_missing"), n + 1, ret_pc, dst: dst, fcall: true)
    end

    def stop
      return trap_call("__fpga_op_stop", [NIL]) if @f.kind == :run && catch?
      return ret(NIL) if @f.kind == :run
      raise Halt
    end

    # --- 回路が持たない命令: __fpga_op_<名前>(a, b, c)
    def trap_op(i)
      @stats[:"op_#{i.name}"] += 1
      trap_call("__fpga_op_#{i.name}", [int(i.a || 0), int(i.b || 0), int(i.c || 0)])
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
          when "__fpga_mcache_fill" then (@cache[[args[0][1], args[1][1]]] = [args[2][1], args[3][1]]; NIL) # (cls, sym, 値, 見つかったクラス)
          when "__fpga_mcache_clear" then (@cache.clear; NIL)
          when "__fpga_mid" then [TAG_SYM, trapped[0].mid] # 罠を起こしたフレームのメソッドの名前 (mruby の ci->mid)
          when "__fpga_proc" then int(trapped[0].proc) # 罠を起こしたフレームの Proc (定数の字句の鎖、super、def の upper)
          when "__fpga_frame_vis" then int(trapped[0].vis) # 罠を起こしたフレームの def の既定の可視性
          when "__fpga_set_caller_vis" then (Ci.new(self, @f.addr - CI_SIZE).vis = args[0][1]; NIL) # 今のメソッドを呼んだフレームの既定の可視性 (private / module_function)
          when "__fpga_class_of" then obj(class_of(args[0])) # 回路の class_of (特異クラスと iclass も含む)
          when "__fpga_sendv" then return sendv(args[0], args[1][1], args[2], args[3], args[4], a, args[5]) # 名前で送る (send / __send__ / public_send)。6 つ目はキーワードの Hash
          when "__fpga_image" then int(r32(args[0][1] * WORD)) # 起動の像の見出しの語
          when "__fpga_reg" then rv(@stbase + (trapped[0].bp + args[0][1]) * VALUE) # 罠を起こしたフレームのレジスタ
          when "__fpga_setreg" then (wv(@stbase + (trapped[0].bp + args[0][1]) * VALUE, args[1]); NIL)
          when "__fpga_irep" then int(trapped[0].irep)
          when "__fpga_ci" then int(trapped[0].addr) # 罠を起こしたフレームの mrb_callinfo の番地 (記憶の中、計画 S2b)
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
          when "__fpga_unwind" then return unwind(args[0][1], args[1][1]) # 例外と break の巻き戻し (vm.c の L_RAISE の cipop と ci->pc)
          when "__fpga_unwind_ret" then return unwind_ret(args[0][1], args[1]) # ci から値を返す (vm.c の L_RETURN)
          when "__fpga_run" then return run_irep(args[0][1], args[1], a)
          when "__fpga_invoke" then return invoke(args[0], args[1][1], args[2], args[3] || NIL, args[4], a, args[5], args[6], args[7]) # 7 つ目はキーワードの Hash、8 つ目はクラスを与えた印
          else raise Error, "primitive #{name} is not implemented"
          end
      setreg(a, r)
    end

    # 上の ci を cipop して ci を今のフレームにする
    def pop_to(ci)
      top = r32(@ctx + CTX_CI)
      raise Error, "unwind to a frame that is not below" unless ci <= top && ci >= r32(@ctx + CTX_CIBASE)

      k = top
      while k > ci
        cipop(k)
        k -= CI_SIZE
      end
      w32(@ctx + CTX_CI, ci)
      @f = Ci.new(self, ci)
    end

    # __fpga_unwind(ci, pc): ci の上を捨て、ci の pc (iseq の中の位置) から続ける
    def unwind(ci, pc)
      pop_to(ci)
      jump(pc)
    end

    # __fpga_unwind_ret(ci, v): ci の上を捨て、ci から v を返す (続きは ret のとおり)
    def unwind_ret(ci, v)
      pop_to(ci)
      ret(v)
    end

    # 一番近い罠のフレームと、その下 (罠を起こした) のフレーム: [起こしたフレーム, 罠のフレーム]
    def trapped
      base = r32(@ctx + CTX_CIBASE)
      ci = @f.addr
      ci -= CI_SIZE while ci > base && Ci.new(self, ci).kind != :trap
      raise Error, "not inside a trap" unless ci > base && Ci.new(self, ci).kind == :trap

      [Ci.new(self, ci - CI_SIZE), Ci.new(self, ci)]
    end

    def alloc(n)
      a = (@heap + 7) & -8
      raise Error, "heap exhausted (GC is S6)" if a + n > @heap_end
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

    # __fpga_invoke(recv, proc, args の配列, blk, mid, tclass, kdict): proc (メソッド表の値でも可、可視性の bit は見ない) を recv で呼ぶ。
    # mid は呼ばれるフレームのメソッドの名前 (super の先も元の名前、mruby の ci->mid)。戻り値は R[a] へ
    # tclass を渡すと、呼ばれるフレームの ci->u.target_class をそれにする (super の見つかったクラス)。
    # given が真なら、クラスを与えられたフレームの印も付ける (vm.c の yield_with_attr: MRB_CI_SET_VISIBILITY_BREAK と MRB_CI_SET_GIVEN_CLASS、class_eval / instance_exec)
    def invoke(recv, pr, args, blk, mid, a, tclass = nil, kdict = nil, given = nil)
      base = r16(@f.irep + I_NREGS)
      list = window(base, recv, args, blk, kdict)
      pr &= ~VIS_MASK
      tc = tclass && tclass[0] == TAG_OBJ && (r32(pr + P_FLAGS) & 3) == PROC_IREP ? tclass[1] : nil
      call_proc(pr, base, list, mid && mid[0] == TAG_SYM ? mid[1] : @f.mid, @pc_next, a, tc)
      w8(@f.addr + CI_VIS, r8(@f.addr + CI_VIS) | CI_VISIBILITY_BREAK_BIT | CI_GIVEN_CLASS_BIT) if tc && given && truthy?(given) && @f.proc == pr
    end

    # __fpga_sendv(recv, sym, args の配列, blk, fcall): 名前で引いて呼ぶ (探索は回路と同じ、fcall なら private も)。戻り値は R[a] へ
    def sendv(recv, sym, args, blk, fcall, a, kdict = nil)
      base = r16(@f.irep + I_NREGS)
      n = window(base, recv, args, blk, kdict)
      dispatch(base, sym, n, @pc_next, dst: a, fcall: truthy?(fcall || NIL))
    end

    # 今のフレームの窓の上に {recv, 引数..., blk} を並べ、引数の数を返す
    # kdict (Hash) があれば引数の後ろに置き、数に CALL_KW を付ける (ci->kw)
    def window(base, recv, args, blk, kdict = nil)
      list = args[0] == TAG_OBJ ? ary_values(args[1]) : []
      setreg(base, recv)
      list.each_with_index { |v, k| setreg(base + 1 + k, v) }
      kw = kdict && kdict[0] == TAG_OBJ
      setreg(base + list.size + 1, kdict) if kw
      setreg(base + list.size + (kw ? 2 : 1), blk)
      list.size | (kw ? CALL_KW : 0)
    end

    # --- ブロックと env (計画 S4-1)
    def env?(u) = !u.zero? && (r32(u + H_FLAGS) & 0xFF) == TT[:ENV]
    def env_len(e) = (r32(e + H_FLAGS) >> H_FLAGS_SHIFT) & 0xFF

    # vm.c の uvenv: 今の Proc から up 段の upper の env (無ければ nil)
    def uvenv(up)
      pr = @f.proc
      up.times do
        pr = r32(pr + P_UPPER)
        return nil if pr.zero?
      end
      (r32(pr + P_FLAGS) & PROC_ENVSET).zero? ? nil : r32(pr + P_ENV)
    end

    # OP_GETUPVAR: R[a] = uvenv(c)[b] (長さの外は nil)
    def getupvar(a, b, c)
      e = uvenv(c)
      setreg(a, e && b < env_len(e) ? rv(r32(e + E_STACK) + b * VALUE) : NIL)
    end

    # OP_SETUPVAR: uvenv(c)[b] = R[a]
    def setupvar(a, b, c)
      e = uvenv(c)
      wv(r32(e + E_STACK) + b * VALUE, reg(a)) if e && b < env_len(e)
    end

    # OP_BLKPUSH (vm.c の vm_op_blkpush): 外の枠のブロックを R[a] へ。無ければ LocalJumpError (罠)
    def blkpush(i, a, b)
      m1 = (b >> 11) & 0x3F
      r = (b >> 10) & 1
      m2 = (b >> 5) & 0x1F
      kd = (b >> 4) & 1
      lv = b & 0xF
      offset = m1 + r + m2 + kd
      if lv.zero?
        v = reg(1 + offset)
      else
        e = uvenv(lv - 1)
        return trap_op(i) if e.nil? || (r32(e + E_CXT).zero? && r32(e + E_MID).zero?) || env_len(e) <= offset + 1
        v = rv(r32(e + E_STACK) + (1 + offset) * VALUE)
      end
      return trap_op(i) if v[0] == TAG_NIL
      setreg(a, v)
    end

    # OP_BLKCALL: R[a] の Proc を R[a+1..a+b] で呼ぶ (cipush の後に vm_call_proc)。Proc でなければ TypeError (罠)
    def blkcall(i, a, b)
      v = reg(a)
      return trap_op(i) unless v[0] == TAG_OBJ && (r32(v[1] + H_FLAGS) & 0xFF) == TT[:PROC]

      push_frame(v[1], a, b, kind: :call, mid: 0, ret_pc: @pc_next)
      vm_call_proc(v[1], b + 1)
    end

    # vm.c の vm_call_proc: 今のフレームで Proc pr を実行する (OP_CALL は Proc#call の irep の中から、OP_BLKCALL は積んだフレームで)。
    # nargs より上を nregs まで nil、env があれば self は env の self
    def vm_call_proc(pr, nargs)
      envset = (r32(pr + P_FLAGS) & PROC_ENVSET) != 0
      env = envset ? r32(pr + P_ENV) : 0
      w32(@f.addr + CI_MID, r32(env + E_MID)) if envset
      w32(@f.addr + CI_U, envset ? r32(env + H_CLASS) : r32(pr + P_TCLASS)) # MRB_PROC_TARGET_CLASS
      raise Error, "calling a C function proc is S5" unless (r32(pr + P_FLAGS) & 3) == PROC_IREP
      w32(@f.addr + CI_PROC, pr)
      @f = Ci.new(self, @f.addr)
      nregs = r16(@f.irep + I_NREGS)
      (nargs...nregs).each { |k| setreg(k, NIL) }
      setreg(0, rv(r32(env + E_STACK))) if envset
      jump(0)
    end

    # vm.c の cipop の mrb_env_unshare: 戻るフレームの env がスタックを指していれば、中身を写して閉じる
    def env_unshare(u)
      return unless env?(u) && !r32(u + E_CXT).zero?

      len = env_len(u)
      if len.zero?
        w32(u + E_STACK, 0)
      else
        buf = alloc(len * VALUE)
        @m[buf, len * VALUE] = @m.byteslice(r32(u + E_STACK), len * VALUE)
        w32(u + E_STACK, buf)
      end
      w32(u + E_CXT, 0)
    end

    def array?(v) = v[0] == TAG_OBJ && (r32(v[1] + H_FLAGS) & 0xFF) == TT[:ARRAY]

    def arycat(i, a)
      x = reg(a)
      v = reg(a + 1)
      return trap_op(i) unless array?(v) && (x[0] == TAG_NIL || array?(x))

      x[0] == TAG_NIL ? setreg(a, alloc_array(ary_values(v[1]))) : ary_append(x[1], ary_values(v[1])) # mrb_ary_splat は複製
    end

    def arypush(i, a, b)
      x = reg(a)
      return trap_op(i) unless array?(x)

      ary_append(x[1], (1..b).map { |k| reg(a + k) })
    end

    # 配列の後ろに足す (array.c の mrb_ary_push / mrb_ary_concat)。容量は ary_expand_capa と同じ (4 から倍にする)
    def ary_append(ary, values)
      len = r32(ary + A_LEN)
      need = len + values.size
      capa = r32(ary + A_CAPA)
      if need > capa
        capa = [capa, 4].max
        capa *= 2 while capa < need
        buf = alloc(capa * VALUE)
        @m[buf, len * VALUE] = @m.byteslice(r32(ary + A_PTR), len * VALUE)
        w32(ary + A_PTR, buf)
        w32(ary + A_CAPA, capa)
      end
      ptr = r32(ary + A_PTR)
      values.each_with_index { |v, k| wv(ptr + (len + k) * VALUE, v) }
      w32(ary + A_LEN, need)
    end

    def ary_values(ary)
      len = r32(ary + A_LEN)
      ptr = r32(ary + A_PTR)
      (0...len).map { |k| rv(ptr + k * VALUE) }
    end
  end
end
