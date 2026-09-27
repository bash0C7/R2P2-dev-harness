# firmware: Proc と env (mruby の src/proc.c と src/vm.c の L_MAKE_LAMBDA、計画 S4-1)。
# 罠を起こしたフレームの mrb_callinfo は記憶にあり (__fpga_ci がその番地)、firmware が直に読み書きする (計画 S2b)
class Object
  # OP_LAMBDA / OP_BLOCK / OP_METHOD: Irep[b] の Proc を作って R[a] へ (c は OP_L_*: bit 0 STRICT、bit 1 CAPTURE)
  # C: src/vm.c OP_LAMBDA
  def __fpga_op_LAMBDA(a, b, c)
    __fpga_make_lambda(a, b, 3) # OP_L_LAMBDA = OP_L_STRICT | OP_L_CAPTURE
  end

  # C: src/vm.c OP_BLOCK
  def __fpga_op_BLOCK(a, b, c)
    __fpga_make_lambda(a, b, 2) # OP_L_BLOCK = OP_L_CAPTURE
  end

  # C: src/vm.c OP_METHOD
  def __fpga_op_METHOD(a, b, c)
    __fpga_make_lambda(a, b, 1) # OP_L_METHOD = OP_L_STRICT
  end

  # C: src/vm.c L_MAKE_LAMBDA
  def __fpga_make_lambda(a, b, c)
    ci = __fpga_ci
    nirep = __fpga_ld32(__fpga_ld32(__fpga_irep + 28) + b * 4) # L:I_REPS
    p = if __fpga_and(c, 2) == 2
          __fpga_closure_new(ci, nirep)
        else
          __fpga_method_proc_new(ci, nirep)
        end
    __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 256)) if __fpga_and(c, 1) == 1 # L:P_FLAGS L:PROC_STRICT
    __fpga_setreg(a, __fpga_obj(p))
  end

  # mrb_proc_new の ci の側: upper は ci->proc、入れ物は ci の cref (無ければ ci の target class)
  # C: src/proc.c mrb_proc_new
  def __fpga_ci_proc_new(ci, irep, flags)
    tc = __fpga_cref_class(ci)
    tc = __fpga_ci_tclass(ci) if tc == 0
    p = __fpga_proc_new(irep, tc, flags)
    __fpga_st32(p + 12, __fpga_ld32(ci + 8)) # L:P_UPPER L:CI_PROC
    p
  end

  # 定数の入れ物: upper の鎖の一番近い cref (MRB_PROC_CREF、クラスを与えられた MRB_PROC_GIVEN は飛ばす)。C の関数なら 0
  # C: src/proc.c mrb_vm_cref_class
  def __fpga_cref_class(ci)
    p = __fpga_ld32(ci + 8) # L:CI_PROC
    while p > 0 && __fpga_and(__fpga_ld32(p + 24), 3) == 0 && (__fpga_and(__fpga_ld32(p + 24), 16384) == 0 || __fpga_and(__fpga_ld32(p + 24), 32768) > 0) # L:P_FLAGS MRB_PROC_CFUNC_P L:PROC_CREF MRB_PROC_GIVEN
      p = __fpga_ld32(p + 12) # L:P_UPPER
    end
    return 0 if p == 0 || __fpga_and(__fpga_ld32(p + 24), 3) > 0 # L:P_FLAGS
    __fpga_proc_target_class(p)
  end

  # def / alias / undef の入れ物: クラスを与えられたフレームならその target class、ほかは cref (与えられた env ならその入れ物)
  # C: src/proc.c mrb_vm_definee_class
  def __fpga_definee_class(ci)
    return __fpga_ci_tclass(ci) if __fpga_and(__fpga_ld8(ci + 2), 16) > 0 # L:CI_VIS L:CI_GIVEN_CLASS_BIT
    p = __fpga_ld32(ci + 8) # L:CI_PROC
    while p > 0 && __fpga_and(__fpga_ld32(p + 24), 3) == 0 # L:P_FLAGS MRB_PROC_CFUNC_P
      return __fpga_proc_target_class(p) if __fpga_and(__fpga_ld32(p + 24), 16384) > 0 # L:PROC_CREF
      return __fpga_ld32(__fpga_proc_env(p) + 0) if __fpga_given_class_env_p(p) # L:H_CLASS MRB_PROC_ENV(p)->c
      p = __fpga_ld32(p + 12) # L:P_UPPER
    end
    0
  end

  # C: src/proc.c given_class_env_p
  def __fpga_given_class_env_p(p)
    e = __fpga_proc_env(p)
    e > 0 && __fpga_and(__fpga_ld32(e + 4), 67108864) > 0 # L:H_FLAGS MRB_ENV_GIVEN_CLASS_P (flags の bit 14 は語の bit 26)
  end

  # C: src/vm.c check_target_class
  def __fpga_check_target_class
    ci = __fpga_ci
    t = __fpga_definee_class(ci)
    t = __fpga_ci_tclass(ci) if t == 0
    __fpga_raise(TypeError, "no class/module to add method") if t == 0
    t
  end

  # C: src/proc.c mrb_closure_new
  def __fpga_closure_new(ci, irep)
    p = __fpga_ci_proc_new(ci, irep, 0)
    __fpga_closure_setup(ci, p)
    p
  end

  # メソッドの本体の Proc: 入れ物は cref (mrb_proc_new)。クラスを与えられた scope なら、そのクラスと MRB_PROC_GIVEN
  # C: src/proc.c mrb_method_proc_new
  def __fpga_method_proc_new(ci, irep)
    p = __fpga_ci_proc_new(ci, irep, 18432) # MRB_PROC_SCOPE | MRB_PROC_CREF
    given = __fpga_definee_class(ci)
    if given > 0 && (given == __fpga_ld32(p + 20)) == false # L:P_TCLASS
      __fpga_st32(p + 20, given) # L:P_TCLASS
      __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 32768)) # L:P_FLAGS MRB_PROC_GIVEN
    end
    p
  end

  # ci に env が無ければ作って ci->u.env に置き、Proc に付ける
  # C: src/proc.c closure_setup
  def __fpga_closure_setup(ci, p)
    e = __fpga_ci_env(ci)
    up = __fpga_ld32(p + 12) # L:P_UPPER
    if e == 0 && up > 0
      tc = __fpga_ci_tclass(ci)
      e = __fpga_env_new(ci, __fpga_u16(__fpga_ld32(up + 8) + 0), __fpga_ld32(ci + 16), tc) # up->body.irep->nlocals L:P_BODY L:I_NLOCALS L:CI_STACK
      __fpga_st32(ci + 24, e) # ci->u.env L:CI_U
    end
    if e > 0
      __fpga_st32(p + 16, e) # L:P_ENV
      __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 1024)) # L:P_FLAGS L:PROC_ENVSET
    end
  end

  # REnv を作る: 入れ物は見出しのクラスの欄、長さと blk の位置は見出しの flags、stack は窓の先頭、cxt は今の mrb_context
  # C: src/proc.c mrb_env_new
  def __fpga_env_new(ci, nstacks, stack, tc)
    e = __fpga_slot(tc, 20) # L:TT_ENV
    n = __fpga_and(__fpga_ld8(ci + 0), 15) # L:CI_N
    kw = __fpga_and(__fpga_shr(__fpga_ld8(ci + 0), 4), 1)
    bidx = 1 + (n == 15 ? 1 : n) + kw
    vis = __fpga_and(__fpga_ld8(ci + 2), 15) # MRB_ENV_COPY_FLAGS_FROM_CI L:CI_VIS
    flags = nstacks + bidx * 256 + vis * 65536 # MRB_ENV_SET_LEN / MRB_ENV_SET_BIDX / flags の 16〜19bit
    pr = __fpga_ld32(ci + 8) # L:CI_PROC
    if tc > 0 && pr > 0 && __fpga_and(__fpga_ld32(pr + 24), 3) == 0 # L:P_FLAGS MRB_PROC_CFUNC_P
      given = __fpga_and(__fpga_ld8(ci + 2), 16) > 0 || (__fpga_and(__fpga_ld32(pr + 24), 16384) == 0 && __fpga_given_class_env_p(pr)) # L:CI_VIS L:CI_GIVEN_CLASS_BIT L:PROC_CREF
      flags += 16384 if given # MRB_ENV_SET_GIVEN_CLASS (flags の bit 14)
    end
    __fpga_st32(e + 4, __fpga_shl(flags, 12) + 20) # L:H_FLAGS L:H_FLAGS_SHIFT L:TT_ENV
    __fpga_st32(e + 8, stack) # L:E_STACK
    __fpga_st32(e + 12, __fpga_image(0)) # L:E_CXT mrb_state.c
    __fpga_st32(e + 16, __fpga_ld32(ci + 4)) # L:E_MID L:CI_MID
    e
  end

  # ブロックを self と定義の入れ物 c で呼ぶ (MRB_CI_SET_VISIBILITY_BREAK と MRB_CI_SET_GIVEN_CLASS)
  # C: src/vm.c yield_with_attr
  def __fpga_yield_with_class(b, args, self_, c)
    p = __fpga_addr(b)
    e = __fpga_proc_env(p)
    mid = e > 0 ? __fpga_mkval(4, __fpga_ld32(e + 16)) : nil # L:TAG_SYM L:E_MID
    __fpga_invoke(self_, p, args, nil, mid, c, nil, true)
  end

  # C: include/mruby/proc.h MRB_PROC_ENV
  def __fpga_proc_env(p)
    __fpga_and(__fpga_ld32(p + 24), 1024) > 0 ? __fpga_ld32(p + 16) : 0 # L:P_FLAGS L:PROC_ENVSET L:P_ENV
  end

  # C: src/proc.c mrb_proc_eql
  def __fpga_proc_eql(a, b)
    return false unless __fpga_tag(a) == 7 && __fpga_tt(__fpga_addr(a)) == 16 # L:TAG_OBJ L:TT_PROC
    return false unless __fpga_tag(b) == 7 && __fpga_tt(__fpga_addr(b)) == 16 # L:TAG_OBJ L:TT_PROC
    p1 = __fpga_addr(a)
    p2 = __fpga_addr(b)
    c1 = __fpga_and(__fpga_ld32(p1 + 24), 3) > 0 # L:P_FLAGS MRB_PROC_CFUNC_P (primitive と attr)
    c2 = __fpga_and(__fpga_ld32(p2 + 24), 3) > 0 # L:P_FLAGS
    return false unless c1 == c2
    return false unless __fpga_ld32(p1 + 8) == __fpga_ld32(p2 + 8) # L:P_BODY
    return true if c1
    __fpga_proc_env(p1) == __fpga_proc_env(p2)
  end

  # 引数の数 (irep の最初の OP_ENTER の aspec から。C の関数の Proc は caspec が無いので -1)。p は Proc の番地
  # C: src/proc.c mrb_proc_arity
  def __fpga_proc_arity(p)
    return 0 if p == 0
    return -1 unless __fpga_and(__fpga_ld32(p + 24), 3) == 0 # L:P_FLAGS L:PROC_IREP MRB_PROC_CFUNC_P (primitive と attr)
    irep = __fpga_ld32(p + 8) # L:P_BODY
    return 0 if irep == 0
    pc = __fpga_ld32(irep + 8) # L:I_ISEQ
    return 0 unless __fpga_ld8(pc) == 57 # L:OP_ENTER
    aspec = __fpga_or(__fpga_or(__fpga_shl(__fpga_ld8(pc + 1), 16), __fpga_shl(__fpga_ld8(pc + 2), 8)), __fpga_ld8(pc + 3)) # PEEK_W
    ma = __fpga_and(__fpga_shr(aspec, 18), 31) # MRB_ASPEC_REQ
    op = __fpga_and(__fpga_shr(aspec, 13), 31) # MRB_ASPEC_OPT
    ra = __fpga_and(__fpga_shr(aspec, 12), 1) # MRB_ASPEC_REST
    pa = __fpga_and(__fpga_shr(aspec, 7), 31) # MRB_ASPEC_POST
    strict = __fpga_and(__fpga_ld32(p + 24), 256) > 0 # L:P_FLAGS L:PROC_STRICT
    return 0 - (ma + pa + 1) if ra > 0 || (strict && op > 0)
    ma + pa
  end

  # ci->u が REnv なら それ、でなければ 0
  # C: src/vm.c mrb_vm_ci_env
  def __fpga_ci_env(ci)
    u = __fpga_ld32(ci + 24) # L:CI_U
    return 0 if u == 0
    __fpga_tt(u) == 20 ? u : 0 # L:TT_ENV
  end

  # ci の target class (env があれば env の見出しのクラス)
  # C: src/vm.c mrb_vm_ci_target_class
  def __fpga_ci_tclass(ci)
    e = __fpga_ci_env(ci)
    e == 0 ? __fpga_ld32(ci + 24) : __fpga_ld32(e) # L:CI_U L:H_CLASS
  end
end

class Proc
  # C: src/proc.c proc_eql
  def ==(other)
    __fpga_proc_eql(self, other)
  end

  alias eql? == # proc.c は == と eql? に同じ関数 proc_eql を置く

  # irep の番地 ^ (env >> 2) ^ MRB_TT_PROC
  # C: src/proc.c proc_hash
  def hash
    p = __fpga_addr(self)
    __fpga_xor(__fpga_xor(__fpga_ld32(p + 8), __fpga_shr(__fpga_proc_env(p), 2)), 16) # L:P_BODY L:TT_PROC
  end

  # Proc.new { } (proc.c の mrb_proc_s_new): ブロックの Proc を写し、initialize を送る。呼んだ所の env を持つ strict でない Proc は ORPHAN
  # C: src/proc.c mrb_proc_s_new
  def self.new(&blk)
    __fpga_raise(ArgumentError, "no block given") if __fpga_tag(blk) == 0 # L:TAG_NIL mrb_get_args の &!
    b = __fpga_addr(blk)
    p = __fpga_slot(__fpga_addr(self), 16) # L:TT_PROC
    __fpga_st32(p + 24, __fpga_ld32(b + 24)) # L:P_FLAGS mrb_proc_copy
    __fpga_st32(p + 8, __fpga_ld32(b + 8)) # L:P_BODY
    __fpga_st32(p + 12, __fpga_ld32(b + 12)) # L:P_UPPER
    __fpga_st32(p + 16, __fpga_ld32(b + 16)) # L:P_ENV
    __fpga_st32(p + 20, __fpga_ld32(b + 20)) # L:P_TCLASS
    proc = __fpga_obj(p)
    __fpga_sendv(proc, :initialize, [], proc, true)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI
    if __fpga_and(__fpga_ld32(p + 24), 256) == 0 && ci > __fpga_cibase && __fpga_proc_env(p) == __fpga_ld32(ci - 64 + 24) # L:P_FLAGS L:PROC_STRICT L:CI_SIZE L:CI_U
      __fpga_st32(p + 24, __fpga_or(__fpga_ld32(p + 24), 512)) # L:P_FLAGS L:PROC_ORPHAN
    end
    proc
  end
end
