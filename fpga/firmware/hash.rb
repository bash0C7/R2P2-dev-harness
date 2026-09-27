# firmware: Hash の C の所 (mruby の src/hash.c と mruby-hash-ext の src/hash_ext.c、vm.c の OP_HASH / HASHADD / HASHCAT)。
# 表は hash.c と同じ 2 つの形: ar (16 行まで、hash_entry の並び ea を線形に探す) と ht (ib の bit 詰めの開番地法で ea の位置を引く)。
# 挿入の順は ea の順。32bit の形 (MRB_32BIT) なので ar の ea_capa / ea_n_used と ht の ib_bit は見出しの flags に置く。
# 関数の引数の h は struct RHash の番地、hash は値 (C の mrb_value)。mrb_free は S6 (確保は bump のまま)
class Object
  # --- flags の欄 (hash.c の DEFINE_FLAG_ACCESSOR / DEFINE_SWITCHER。見出しの語の H_FLAGS_SHIFT から上が flags:20)
  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_h_flags(h)
    __fpga_shr(__fpga_ld32(h + 4), 12) # L:H_FLAGS L:H_FLAGS_SHIFT
  end

  # 下の 12bit (tt、gc の色、frozen) は残す
  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_h_set_flags(h, f)
    __fpga_st32(h + 4, __fpga_or(__fpga_and(__fpga_ld32(h + 4), 4095), __fpga_shl(f, 12))) # L:H_FLAGS L:H_FLAGS_SHIFT
  end

  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ar_ea_capa(h)
    __fpga_and(__fpga_h_flags(h), 31) # L:MRB_HASH_AR_EA_CAPA_MASK
  end

  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ar_set_ea_capa(h, v)
    __fpga_h_set_flags(h, __fpga_or(__fpga_xor(__fpga_or(__fpga_h_flags(h), 31), 31), v)) # L:MRB_HASH_AR_EA_CAPA_MASK
  end

  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ar_ea_n_used(h)
    __fpga_and(__fpga_shr(__fpga_h_flags(h), 5), 31) # L:MRB_HASH_AR_EA_N_USED_SHIFT L:MRB_HASH_AR_EA_CAPA_MASK
  end

  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ar_set_ea_n_used(h, v)
    f = __fpga_xor(__fpga_or(__fpga_h_flags(h), 992), 992) # L:MRB_HASH_AR_EA_N_USED_MASK
    __fpga_h_set_flags(h, __fpga_or(f, __fpga_shl(v, 5))) # L:MRB_HASH_AR_EA_N_USED_SHIFT
  end

  # ib_bit (ar の ea_capa と同じ bit。ht の時だけ)
  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ib_bit(h)
    __fpga_and(__fpga_h_flags(h), 31) # L:MRB_HASH_IB_BIT_MASK
  end

  # C: src/hash.c DEFINE_FLAG_ACCESSOR
  def __fpga_ib_set_bit(h, v)
    __fpga_h_set_flags(h, __fpga_or(__fpga_xor(__fpga_or(__fpga_h_flags(h), 31), 31), v)) # L:MRB_HASH_IB_BIT_MASK
  end

  # C: src/hash.c DEFINE_SWITCHER
  def __fpga_h_ht_p(h)
    __fpga_and(__fpga_h_flags(h), 4096) > 0 # L:MRB_HASH_HT
  end

  # h_ht_on (on が真) と h_ht_off
  # C: src/hash.c DEFINE_SWITCHER
  def __fpga_h_ht_set(h, on)
    f = __fpga_xor(__fpga_or(__fpga_h_flags(h), 4096), 4096) # L:MRB_HASH_HT
    __fpga_h_set_flags(h, on ? __fpga_or(f, 4096) : f) # L:MRB_HASH_HT
  end

  # h の size (ar_size と ht_size は同じ欄)
  # C: src/hash.c DEFINE_GETTER
  def __fpga_h_size(h)
    __fpga_ld32(h + 8) # L:HS_SIZE
  end

  # ar は ea そのもの、ht は hash_table の ea
  # C: src/hash.c DEFINE_ACCESSOR
  def __fpga_h_ea(h)
    t = __fpga_ld32(h + 12) # L:HS_HSH
    __fpga_h_ht_p(h) ? __fpga_ld32(t + 0) : t # L:HT_EA
  end

  # ht_ea_capa / ar_ea_capa
  # C: src/hash.c DEFINE_ACCESSOR
  def __fpga_h_ea_capa(h)
    __fpga_h_ht_p(h) ? __fpga_ld32(__fpga_ld32(h + 12) + 4) : __fpga_ar_ea_capa(h) # L:HS_HSH L:HT_EA_CAPA
  end

  # --- mrb_malloc / mrb_realloc (gc.c)。大きさの語を前に置く (realloc が写す長さを知るため。estalloc の見出しの代わりで、S6 で写す)
  # C: src/gc.c mrb_malloc
  def __fpga_malloc(len)
    p = __fpga_alloc(len + 8)
    __fpga_st32(p, len)
    p + 8
  end

  # C: src/gc.c mrb_realloc
  def __fpga_realloc(p, len)
    p2 = __fpga_malloc(len)
    if p > 0
      old = __fpga_ld32(p - 8)
      __fpga_copy(p2, p, old < len ? old : len)
    end
    p2
  end

  # --- H_CHECK_MODIFIED: 呼び出しの前後で表が替わったら RuntimeError。表が無ければ (tbl が NULL) 中身を実行しない。
  # 32bit の MRB_NO_BOXING は ar の ht_ea と ht_ea_capa を見ない (H_CHECK_MODIFIED_USE_HT_EA_FOR_AR が FALSE)
  # C: src/hash.c h_check_modified_init
  def __fpga_h_check_modified_init(h)
    tbl = __fpga_ld32(h + 12) # L:HS_HSH
    return 0 if tbl == 0
    c = __fpga_alloc(16) # L:HCM_SIZE
    __fpga_st32(c + 0, __fpga_and(__fpga_h_flags(h), 4127)) # L:HCM_FLAGS L:H_CHECK_MODIFIED_FLAGS_MASK
    __fpga_st32(c + 4, tbl) # L:HCM_TBL
    ht = __fpga_h_ht_p(h)
    __fpga_st32(c + 8, ht ? __fpga_ld32(tbl + 4) : 0) # L:HCM_EA_CAPA L:HT_EA_CAPA
    __fpga_st32(c + 12, ht ? __fpga_ld32(tbl + 0) : 0) # L:HCM_EA L:HT_EA
    c
  end

  # C: src/hash.c h_check_modified_validate
  def __fpga_h_check_modified_validate(c, h)
    tbl = __fpga_ld32(h + 12) # L:HS_HSH
    bad = __fpga_ld32(c + 0) == __fpga_and(__fpga_h_flags(h), 4127) ? false : true # L:HCM_FLAGS L:H_CHECK_MODIFIED_FLAGS_MASK
    bad = true unless __fpga_ld32(c + 4) == tbl # L:HCM_TBL
    if bad == false && __fpga_h_ht_p(h)
      bad = true unless __fpga_ld32(c + 8) == __fpga_ld32(tbl + 4) # L:HCM_EA_CAPA L:HT_EA_CAPA
      bad = true unless __fpga_ld32(c + 12) == __fpga_ld32(tbl + 0) # L:HCM_EA L:HT_EA
    end
    __fpga_raise(RuntimeError, "hash modified") if bad
  end

  # --- ハッシュの値
  # C: src/hash.c mrb_obj_hash_code
  def __fpga_obj_hash_code(key)
    t = __fpga_tag(key)
    if t == 7 && __fpga_tt(__fpga_addr(key)) == 18 # L:TAG_OBJ L:TT_STRING
      hc = __fpga_str_hash(key)
    elsif t <= 2 # L:TAG_TRUE nil、false、true (MRB_TT_FALSE / TRUE の mrb_fixnum)
      hc = __fpga_and(__fpga_int(key), 4294967295)
    elsif t == 4 # L:TAG_SYM mrb_symbol
      hc = __fpga_and(__fpga_int(key), 4294967295)
    elsif t == 3 # L:TAG_INT
      hc = __fpga_and(key, 4294967295)
    elsif t == 5 # L:TAG_FLOAT
      hc = __fpga_float_hash_code(key)
    else
      hc = __fpga_xor(__fpga_tt(__fpga_addr(key)), __fpga_and(__fpga_int(key.hash), 4294967295)) # U32(tt) ^ U32(mrb_integer(...))
    end
    hc = __fpga_xor(hc, __fpga_shr(hc, 16))
    hc = __fpga_and(hc * 73244475, 4294967295) # 0x45d9f3b
    __fpga_xor(hc, __fpga_shr(hc, 16))
  end

  # -0.0 は 0.0 にそろえて、double の 8 バイトを FNV-1a で (バイトの順は host と同じ little endian)
  # C: src/hash.c float_hash_code
  def __fpga_float_hash_code(f)
    bits = __fpga_int(f)
    bits = 0 if bits == __fpga_shl(1, 63) # -0.0
    __fpga_int64_byte_hash(bits)
  end

  # obj_hash_code: key の hash を呼ぶ間に h が替わったら RuntimeError
  # C: src/hash.c obj_hash_code
  def __fpga_h_obj_hash_code(key, h)
    hc = 0
    c = __fpga_h_check_modified_init(h)
    if c > 0
      hc = __fpga_obj_hash_code(key)
      __fpga_h_check_modified_validate(c, h)
    end
    hc
  end

  # 鍵が同じか (String、Symbol、Integer、Float はその場で、ほかは mrb_eql)
  # C: src/hash.c obj_eql
  def __fpga_obj_eql(a, b, h)
    t = __fpga_tag(a)
    if t == 7 && __fpga_tt(__fpga_addr(a)) == 18 # L:TAG_OBJ L:TT_STRING
      return __fpga_str_equal(a, b)
    elsif t == 4 || t == 3 # L:TAG_SYM L:TAG_INT
      return __fpga_tag(b) == t && __fpga_int(a) == __fpga_int(b)
    elsif t == 5 # L:TAG_FLOAT
      return false unless __fpga_tag(b) == 5 # L:TAG_FLOAT
      return true if __fpga_f64_cmp(__fpga_int(a), __fpga_int(b)) == 0 # fa == mrb_float(b)
      return __fpga_int(a) == __fpga_int(b) # mrb_obj_eq (NaN は通し番号まで同じもの)
    end
    eql = false
    c = __fpga_h_check_modified_init(h)
    if c > 0
      eql = __fpga_eql(a, b)
      __fpga_h_check_modified_validate(c, h)
    end
    eql
  end

  # --- hash_entry の並び (ea)
  # C: src/hash.c entry_deleted_p
  def __fpga_entry_deleted_p(e)
    __fpga_ld32(e + 0) == 6 # L:HE_KEY L:TAG_UNDEF
  end

  # C: src/hash.c entry_delete
  def __fpga_entry_delete(e)
    __fpga_stv(e + 0, __fpga_undef) # L:HE_KEY
  end

  # C: src/hash.c entry_skip_deleted
  def __fpga_entry_skip_deleted(e)
    e += 32 while __fpga_entry_deleted_p(e) # L:HASH_ENTRY
    e
  end

  # C: src/hash.c entry_skip_deleted_bounded
  def __fpga_entry_skip_deleted_bounded(e, en)
    e += 32 while e < en && __fpga_entry_deleted_p(e) # L:HASH_ENTRY
    e
  end

  # C: src/hash.c ea_next_capa_for
  def __fpga_ea_next_capa_for(size, max_capa)
    return 4 if size < 4 # L:AR_DEFAULT_CAPA
    capa = size * 6 / 5 + 6
    capa = size + 65535 if 65535 < capa - size # L:EA_MAX_INCREASE
    capa <= max_capa ? capa : max_capa
  end

  # C: src/hash.c ea_resize
  def __fpga_ea_resize(ea, old_capa, capa)
    ea = __fpga_realloc(ea, capa * 32) # L:HASH_ENTRY
    i = old_capa
    while i < capa
      __fpga_entry_delete(ea + i * 32) # L:HASH_ENTRY
      i += 1
    end
    ea
  end

  # C: src/hash.c ea_compress
  def __fpga_ea_compress(ea, n_used)
    w = ea
    r = ea
    en = ea + n_used * 32 # L:HASH_ENTRY
    while r < en
      unless __fpga_entry_deleted_p(r)
        __fpga_copy(w, r, 32) unless r == w # L:HASH_ENTRY
        w += 32 # L:HASH_ENTRY
      end
      r += 32 # L:HASH_ENTRY
    end
    while w < en
      __fpga_entry_delete(w)
      w += 32 # L:HASH_ENTRY
    end
  end

  # C: src/hash.c ea_dup
  def __fpga_ea_dup(ea, capa)
    n = __fpga_malloc(capa * 32) # L:HASH_ENTRY
    __fpga_copy(n, ea, capa * 32) # L:HASH_ENTRY
    n
  end

  # 見つかった行の番地 (無ければ 0)
  # C: src/hash.c ea_get_by_key
  def __fpga_ea_get_by_key(ea, size, key, h)
    e = ea
    while size > 0
      e = __fpga_entry_skip_deleted(e)
      return e if __fpga_obj_eql(key, __fpga_ldv(e + 0), h) # L:HE_KEY
      e += 32 # L:HASH_ENTRY
      size -= 1
    end
    0
  end

  # C: src/hash.c ea_set
  def __fpga_ea_set(ea, index, key, val)
    __fpga_stv(ea + index * 32 + 0, key) # L:HASH_ENTRY L:HE_KEY
    __fpga_stv(ea + index * 32 + 16, val) # L:HASH_ENTRY L:HE_VAL
  end

  # --- ar (Array Table)
  # C: src/hash.c ar_init
  def __fpga_ar_init(h, size, ea, ea_capa, ea_n_used)
    __fpga_h_ht_set(h, false) # h_ar_on
    __fpga_st32(h + 8, size) # L:HS_SIZE
    __fpga_st32(h + 12, ea) # L:HS_HSH
    __fpga_ar_set_ea_capa(h, ea_capa)
    __fpga_ar_set_ea_n_used(h, ea_n_used)
  end

  # C: src/hash.c ar_adjust_ea
  def __fpga_ar_adjust_ea(h, size, max_ea_capa)
    ea_capa = __fpga_ea_next_capa_for(size, max_ea_capa) # ea_adjust (*capap = size から)
    __fpga_st32(h + 12, __fpga_ea_resize(__fpga_ld32(h + 12), size, ea_capa)) # L:HS_HSH
    __fpga_ar_set_ea_capa(h, ea_capa)
  end

  # C: src/hash.c ar_compress
  def __fpga_ar_compress(h)
    size = __fpga_h_size(h)
    __fpga_ea_compress(__fpga_ld32(h + 12), __fpga_ar_ea_n_used(h)) # L:HS_HSH
    __fpga_ar_set_ea_n_used(h, size)
    capa = __fpga_ar_ea_capa(h)
    __fpga_ar_adjust_ea(h, size, capa < 16 ? capa : 16) # L:AR_MAX_SIZE
  end

  # 値 (無ければ undef。C は *valp と真偽)
  # C: src/hash.c ar_get
  def __fpga_ar_get(h, key)
    e = __fpga_ld32(h + 12) # L:HS_HSH
    size = __fpga_h_size(h)
    while size > 0
      e = __fpga_entry_skip_deleted(e)
      return __fpga_ldv(e + 16) if __fpga_obj_eql(key, __fpga_ldv(e + 0), h) # L:HE_VAL L:HE_KEY
      e += 32 # L:HASH_ENTRY
      size -= 1
    end
    __fpga_undef
  end

  # C: src/hash.c ar_set
  def __fpga_ar_set(h, key, val)
    size = __fpga_h_size(h)
    e = __fpga_ea_get_by_key(__fpga_ld32(h + 12), size, key, h) # L:HS_HSH
    if e > 0
      __fpga_stv(e + 16, val) # L:HE_VAL
      return
    end
    ea_capa = __fpga_ar_ea_capa(h)
    ea_n_used = __fpga_ar_ea_n_used(h)
    key = __fpga_h_key_for(h, key)
    if ea_capa == ea_n_used
      if size == ea_n_used
        if size == 16 # L:AR_MAX_SIZE
          __fpga_ht_init(h, size, __fpga_ld32(h + 12), ea_capa, 0, 5) # L:HS_HSH L:IB_INIT_BIT
          __fpga_ht_set(h, key, val)
          return
        end
        __fpga_ar_adjust_ea(h, size, 16) # L:AR_MAX_SIZE
      else
        __fpga_ar_compress(h)
        ea_n_used = size
      end
    end
    __fpga_ea_set(__fpga_ld32(h + 12), ea_n_used, key, val) # L:HS_HSH
    __fpga_st32(h + 8, size + 1) # L:HS_SIZE
    __fpga_ar_set_ea_n_used(h, ea_n_used + 1)
  end

  # 消した値 (無ければ undef)
  # C: src/hash.c ar_delete
  def __fpga_ar_delete(h, key)
    e = __fpga_ea_get_by_key(__fpga_ld32(h + 12), __fpga_h_size(h), key, h) # L:HS_HSH
    return __fpga_undef if e == 0
    v = __fpga_ldv(e + 16) # L:HE_VAL
    __fpga_entry_delete(e)
    __fpga_st32(h + 8, __fpga_h_size(h) - 1) # L:HS_SIZE ar_dec_size
    v
  end

  # 最初の行を外して [key, val] (C は *keyp と *valp)
  # C: src/hash.c ar_shift
  def __fpga_ar_shift(h)
    size = __fpga_h_size(h)
    e = __fpga_entry_skip_deleted(__fpga_ld32(h + 12)) # L:HS_HSH
    kv = [__fpga_ldv(e + 0), __fpga_ldv(e + 16)] # L:HE_KEY L:HE_VAL
    __fpga_entry_delete(e)
    __fpga_st32(h + 8, size - 1) # L:HS_SIZE
    kv
  end

  # C: src/hash.c ar_rehash
  def __fpga_ar_rehash(h)
    size = __fpga_h_size(h)
    w_size = 0
    ea_capa = __fpga_ar_ea_capa(h)
    ea = __fpga_ld32(h + 12) # L:HS_HSH
    r = ea
    n = size
    while n > 0
      r = __fpga_entry_skip_deleted(r)
      w = __fpga_ea_get_by_key(ea, w_size, __fpga_ldv(r + 0), h) # L:HE_KEY
      if w > 0
        __fpga_stv(w + 16, __fpga_ldv(r + 16)) # L:HE_VAL
        size -= 1
        __fpga_st32(h + 8, size) # L:HS_SIZE
        __fpga_entry_delete(r)
      else
        unless w_size == (r - ea) / 32 # L:HASH_ENTRY
          __fpga_ea_set(ea, w_size, __fpga_ldv(r + 0), __fpga_ldv(r + 16)) # L:HE_KEY L:HE_VAL
          __fpga_entry_delete(r)
        end
        w_size += 1
      end
      r += 32 # L:HASH_ENTRY
      n -= 1
    end
    __fpga_ar_set_ea_n_used(h, size)
    __fpga_ar_adjust_ea(h, size, ea_capa)
  end

  # --- ib (Index Buckets)。it は index_buckets_iter の記憶 (layout.rb の IT_*)
  # C: src/hash.c ib_it_init
  def __fpga_ib_it_init(h, key)
    it = __fpga_alloc(40) # L:IT_SIZE
    bit = __fpga_ib_bit(h)
    mask = __fpga_shl(1, bit) - 1 # ib_bit_to_capa
    __fpga_st32(it + 0, h) # L:IT_H
    __fpga_st32(it + 4, bit) # L:IT_BIT
    __fpga_st32(it + 8, mask) # L:IT_MASK
    pos = __fpga_and(__fpga_h_obj_hash_code(key, h), mask) # ib_it_pos_for
    __fpga_st32(it + 12, pos) # L:IT_INITIAL_POS
    __fpga_st32(it + 16, pos) # L:IT_POS
    __fpga_st32(it + 36, 0) # L:IT_STEP
    it
  end

  # 次の bucket へ進み、その値 (ea の位置) を読む。値は bit 幅で詰めてあり、2 つの語にまたがる時は前の語からも取る
  # C: src/hash.c ib_it_next
  def __fpga_ib_it_next(it)
    pos = __fpga_ld32(it + 16) # L:IT_POS
    bit = __fpga_ld32(it + 4) # L:IT_BIT
    mask = __fpga_ld32(it + 8) # L:IT_MASK
    ib = __fpga_ld32(__fpga_ld32(it + 0) + 12) + 12 # L:IT_H L:HS_HSH L:HT_IB
    slid_pos = __fpga_and(pos, 31) # IB_TYPE_BIT - 1
    slid_bit_pos = bit * (slid_pos + 1) - 1
    slid_ary_index = slid_bit_pos / 32 # L:IB_TYPE_BIT
    ary_index = slid_ary_index + pos / 32 * bit # L:IB_TYPE_BIT
    shift2 = (slid_ary_index + 1) * 32 - slid_bit_pos - 1 # L:IB_TYPE_BIT
    ea_index = __fpga_and(__fpga_shr(__fpga_ld32(ib + ary_index * 4), shift2), mask)
    shift1 = 0
    if 32 - bit < shift2 # L:IB_TYPE_BIT
      shift1 = 32 - shift2 # L:IB_TYPE_BIT
      ea_index = __fpga_or(ea_index, __fpga_and(__fpga_shl(__fpga_ld32(ib + (ary_index - 1) * 4), shift1), mask))
    end
    step = __fpga_ld32(it + 36) + 1 # L:IT_STEP
    __fpga_st32(it + 20, ary_index) # L:IT_ARY_INDEX
    __fpga_st32(it + 24, ea_index) # L:IT_EA_INDEX
    __fpga_st32(it + 28, shift1) # L:IT_SHIFT1
    __fpga_st32(it + 32, shift2) # L:IT_SHIFT2
    __fpga_st32(it + 36, step) # L:IT_STEP
    __fpga_st32(it + 16, __fpga_and(__fpga_ld32(it + 12) + (step * step + step) / 2, mask)) # L:IT_POS L:IT_INITIAL_POS
  end

  # 空き (mask)、消した印 (mask - 1)、使っている (それより小さい)
  # C: src/hash.c ib_it_empty_p
  def __fpga_ib_it_empty_p(it)
    __fpga_ld32(it + 24) == __fpga_ld32(it + 8) # L:IT_EA_INDEX L:IT_MASK
  end

  # C: src/hash.c ib_it_deleted_p
  def __fpga_ib_it_deleted_p(it)
    __fpga_ld32(it + 24) == __fpga_ld32(it + 8) - 1 # L:IT_EA_INDEX L:IT_MASK
  end

  # C: src/hash.c ib_it_active_p
  def __fpga_ib_it_active_p(it)
    __fpga_ld32(it + 24) < __fpga_ld32(it + 8) - 1 # L:IT_EA_INDEX L:IT_MASK
  end

  # C: src/hash.c ib_it_find_by_key
  def __fpga_ib_it_find_by_key(it, key)
    h = __fpga_ld32(it + 0) # L:IT_H
    return false if h == 0
    while true
      __fpga_ib_it_next(it)
      return false if __fpga_ib_it_empty_p(it)
      if __fpga_ib_it_deleted_p(it) == false
        return true if __fpga_obj_eql(key, __fpga_ldv(__fpga_ib_it_entry(it) + 0), h) # L:HE_KEY
      end
    end
  end

  # C: src/hash.c ib_it_set
  def __fpga_ib_it_set(it, ea_index)
    __fpga_st32(it + 24, ea_index) # L:IT_EA_INDEX
    ib = __fpga_ld32(__fpga_ld32(it + 0) + 12) + 12 # L:IT_H L:HS_HSH L:HT_IB
    mask0 = __fpga_ld32(it + 8) # L:IT_MASK
    ary_index = __fpga_ld32(it + 20) # L:IT_ARY_INDEX
    shift1 = __fpga_ld32(it + 28) # L:IT_SHIFT1
    if shift1 > 0
      a = ib + (ary_index - 1) * 4
      mask = __fpga_shr(mask0, shift1)
      __fpga_st32(a, __fpga_or(__fpga_xor(__fpga_or(__fpga_ld32(a), mask), mask), __fpga_shr(ea_index, shift1)))
    end
    a = ib + ary_index * 4
    shift2 = __fpga_ld32(it + 32) # L:IT_SHIFT2
    mask = __fpga_and(__fpga_shl(mask0, shift2), 4294967295)
    __fpga_st32(a, __fpga_or(__fpga_xor(__fpga_or(__fpga_ld32(a), mask), mask), __fpga_and(__fpga_shl(ea_index, shift2), 4294967295)))
  end

  # C: src/hash.c ib_it_delete
  def __fpga_ib_it_delete(it)
    __fpga_ib_it_set(it, __fpga_ld32(it + 8) - 1) # L:IT_MASK ib_it_deleted_value
  end

  # C: src/hash.c ib_it_entry
  def __fpga_ib_it_entry(it)
    __fpga_ld32(__fpga_ld32(__fpga_ld32(it + 0) + 12) + 0) + __fpga_ld32(it + 24) * 32 # L:IT_H L:HS_HSH L:HT_EA L:IT_EA_INDEX L:HASH_ENTRY
  end

  # C: src/hash.c ib_capa_to_bit
  def __fpga_ib_capa_to_bit(capa)
    bit = 0
    while __fpga_and(capa, 1) == 0 # __builtin_ctz
      capa = __fpga_shr(capa, 1)
      bit += 1
    end
    bit
  end

  # C: src/hash.c ib_upper_bound_for
  def __fpga_ib_upper_bound_for(capa)
    __fpga_or(__fpga_shr(capa, 2), __fpga_shr(capa, 1)) # 3/4
  end

  # C: src/hash.c ib_bit_for
  def __fpga_ib_bit_for(size)
    capa = 1 # next_power2 (size より大きい 2 の冪)
    capa *= 2 while capa <= size
    capa *= 2 if capa < 2147483648 && __fpga_ib_upper_bound_for(capa) < size # IB_MAX_CAPA (capa != IB_MAX_CAPA)
    __fpga_ib_capa_to_bit(capa)
  end

  # C: src/hash.c ib_byte_size_for
  def __fpga_ib_byte_size_for(ib_bit)
    4 * (__fpga_shl(1, ib_bit) / 32 * ib_bit) # L:IB_TYPE_BIT (IB_INIT_BIT は 4 でない)
  end

  # C: src/hash.c ib_init
  def __fpga_ib_init(h, ib_bit, ib_byte_size)
    ea = __fpga_h_ea(h)
    ib = __fpga_ld32(h + 12) + 12 # L:HS_HSH L:HT_IB
    k = 0
    while k < ib_byte_size # memset 0xff
      __fpga_st32(ib + k, 4294967295)
      k += 4
    end
    __fpga_ib_set_bit(h, ib_bit)
    n_used = __fpga_ld32(__fpga_ld32(h + 12) + 8) # L:HS_HSH L:HT_EA_N_USED
    e = ea
    while e < ea + n_used * 32 # L:HASH_ENTRY EA_EACH_USED
      it = __fpga_ib_it_init(h, __fpga_ldv(e + 0)) # L:HE_KEY IB_CYCLE_BY_KEY
      while true
        __fpga_ib_it_next(it)
        next unless __fpga_ib_it_empty_p(it)
        __fpga_ib_it_set(it, (e - ea) / 32) # L:HASH_ENTRY
        break
      end
      e += 32 # L:HASH_ENTRY
    end
  end

  # --- ht (Hash Table)
  # C: src/hash.c ht_init
  def __fpga_ht_init(h, size, ea, ea_capa, ht, ib_bit)
    ib_byte_size = __fpga_ib_byte_size_for(ib_bit)
    ht = __fpga_realloc(ht, 12 + ib_byte_size) # L:HT_IB sizeof(hash_table)
    __fpga_h_ht_set(h, true)
    __fpga_st32(h + 12, ht) # L:HS_HSH
    __fpga_st32(h + 8, size) # L:HS_SIZE
    __fpga_st32(ht + 0, ea) # L:HT_EA
    __fpga_st32(ht + 4, ea_capa) # L:HT_EA_CAPA
    __fpga_st32(ht + 8, size) # L:HT_EA_N_USED
    __fpga_ib_init(h, ib_bit, ib_byte_size)
  end

  # C: src/hash.c ht_dup
  def __fpga_ht_dup(h)
    n = 12 + __fpga_ib_byte_size_for(__fpga_ib_bit(h)) # L:HT_IB
    t = __fpga_malloc(n)
    __fpga_copy(t, __fpga_ld32(h + 12), n) # L:HS_HSH
    t
  end

  # C: src/hash.c ht_adjust_ea
  def __fpga_ht_adjust_ea(h, size, max_ea_capa)
    ht = __fpga_ld32(h + 12) # L:HS_HSH
    ea_capa = __fpga_ea_next_capa_for(size, max_ea_capa) # ea_adjust (*capap = size から)
    __fpga_st32(ht + 0, __fpga_ea_resize(__fpga_ld32(ht + 0), size, ea_capa)) # L:HT_EA
    __fpga_st32(ht + 4, ea_capa) # L:HT_EA_CAPA
  end

  # C: src/hash.c ht_to_ar
  def __fpga_ht_to_ar(h)
    ht = __fpga_ld32(h + 12) # L:HS_HSH
    size = __fpga_h_size(h)
    ea = __fpga_ld32(ht + 0) # L:HT_EA
    __fpga_ea_compress(ea, __fpga_ld32(ht + 8)) # L:HT_EA_N_USED
    ea_capa = __fpga_ea_next_capa_for(size, 16) # L:AR_MAX_SIZE ea_adjust
    ea = __fpga_ea_resize(ea, size, ea_capa)
    __fpga_ar_init(h, size, ea, ea_capa, size)
  end

  # C: src/hash.c ht_get
  def __fpga_ht_get(h, key)
    it = __fpga_ib_it_init(h, key) # IB_FIND_BY_KEY
    return __fpga_ldv(__fpga_ib_it_entry(it) + 16) if __fpga_ib_it_find_by_key(it, key) # L:HE_VAL
    __fpga_undef
  end

  # C: src/hash.c ht_set_as_ar
  def __fpga_ht_set_as_ar(h, key, val)
    __fpga_ht_to_ar(h)
    __fpga_ar_set(h, key, val)
  end

  # C: src/hash.c ht_set
  def __fpga_ht_set(h, key, val)
    size = __fpga_h_size(h)
    ib_bit_width = __fpga_ib_bit(h)
    ib_capa = __fpga_shl(1, ib_bit_width)
    ht = __fpga_ld32(h + 12) # L:HS_HSH
    if __fpga_ib_upper_bound_for(ib_capa) <= size
      __fpga_ea_compress(__fpga_ld32(ht + 0), __fpga_ld32(ht + 8)) unless size == __fpga_ld32(ht + 8) # L:HT_EA L:HT_EA_N_USED
      __fpga_ht_init(h, size, __fpga_ld32(ht + 0), __fpga_ld32(ht + 4), ht, ib_bit_width + 1) # L:HT_EA L:HT_EA_CAPA
    elsif (size == __fpga_ld32(ht + 8)) == false # L:HT_EA_N_USED
      compress = false
      if ib_capa - 2 <= __fpga_ld32(ht + 8) # L:EA_N_RESERVED_INDICES L:HT_EA_N_USED
        compress = true
      elsif __fpga_ld32(ht + 4) == __fpga_ld32(ht + 8) # L:HT_EA_CAPA L:HT_EA_N_USED
        if size <= 16 # L:AR_MAX_SIZE
          __fpga_ht_set_as_ar(h, key, val)
          return
        end
        compress = true if __fpga_ea_next_capa_for(size, 2147483646) <= __fpga_ld32(ht + 4) # L:EA_MAX_CAPA L:HT_EA_CAPA
      end
      if compress # compress:
        __fpga_ea_compress(__fpga_ld32(ht + 0), __fpga_ld32(ht + 8)) # L:HT_EA L:HT_EA_N_USED
        __fpga_ht_adjust_ea(h, size, __fpga_ld32(ht + 4)) # L:HT_EA_CAPA
        __fpga_ht_init(h, size, __fpga_ld32(ht + 0), __fpga_ld32(ht + 4), ht, ib_bit_width) # L:HT_EA L:HT_EA_CAPA
      end
    end
    it = __fpga_ib_it_init(h, key) # IB_CYCLE_BY_KEY
    while true
      __fpga_ib_it_next(it)
      if __fpga_ib_it_active_p(it)
        e = __fpga_ib_it_entry(it)
        next unless __fpga_obj_eql(key, __fpga_ldv(e + 0), h) # L:HE_KEY
        __fpga_stv(__fpga_ib_it_entry(it) + 16, val) # L:HE_VAL
      elsif __fpga_ib_it_deleted_p(it)
        next
      else
        ht = __fpga_ld32(h + 12) # L:HS_HSH
        ea_n_used = __fpga_ld32(ht + 8) # L:HT_EA_N_USED
        __fpga_raise(ArgumentError, "hash too big") if ea_n_used == 2147483646 # L:EA_MAX_CAPA H_MAX_SIZE
        key = __fpga_h_key_for(h, key)
        __fpga_ht_adjust_ea(h, ea_n_used, 2147483646) if ea_n_used == __fpga_ld32(ht + 4) # L:EA_MAX_CAPA L:HT_EA_CAPA
        __fpga_ib_it_set(it, ea_n_used)
        __fpga_ea_set(__fpga_ld32(ht + 0), ea_n_used, key, val) # L:HT_EA
        __fpga_st32(h + 8, __fpga_h_size(h) + 1) # L:HS_SIZE ht_inc_size
        __fpga_st32(ht + 8, ea_n_used + 1) # L:HT_EA_N_USED
      end
      return
    end
  end

  # C: src/hash.c ht_delete
  def __fpga_ht_delete(h, key)
    it = __fpga_ib_it_init(h, key) # IB_FIND_BY_KEY
    return __fpga_undef unless __fpga_ib_it_find_by_key(it, key)
    e = __fpga_ib_it_entry(it)
    v = __fpga_ldv(e + 16) # L:HE_VAL
    __fpga_ib_it_delete(it)
    __fpga_entry_delete(e)
    __fpga_st32(h + 8, __fpga_h_size(h) - 1) # L:HS_SIZE ht_dec_size
    v
  end

  # C: src/hash.c ht_shift
  def __fpga_ht_shift(h)
    ea = __fpga_h_ea(h)
    e = __fpga_entry_skip_deleted(ea) # EA_EACH の最初の行
    it = __fpga_ib_it_init(h, __fpga_ldv(e + 0)) # L:HE_KEY IB_CYCLE_BY_KEY
    while true
      __fpga_ib_it_next(it)
      next unless __fpga_ld32(it + 24) == (e - ea) / 32 # L:IT_EA_INDEX L:HASH_ENTRY ib_it_get
      kv = [__fpga_ldv(e + 0), __fpga_ldv(e + 16)] # L:HE_KEY L:HE_VAL
      __fpga_ib_it_delete(it)
      __fpga_entry_delete(e)
      __fpga_st32(h + 8, __fpga_h_size(h) - 1) # L:HS_SIZE ht_dec_size
      return kv
    end
  end

  # C: src/hash.c ht_rehash
  def __fpga_ht_rehash(h)
    size = __fpga_h_size(h)
    if size <= 16 # L:AR_MAX_SIZE
      __fpga_ht_to_ar(h)
      __fpga_ar_rehash(h)
      return
    end
    w_size = 0
    ht = __fpga_ld32(h + 12) # L:HS_HSH
    ea_capa = __fpga_ld32(ht + 4) # L:HT_EA_CAPA
    ea = __fpga_ld32(ht + 0) # L:HT_EA
    __fpga_ht_init(h, 0, ea, ea_capa, ht, __fpga_ib_bit_for(size))
    ht = __fpga_ld32(h + 12) # L:HS_HSH
    __fpga_st32(h + 8, size) # L:HS_SIZE
    __fpga_st32(ht + 8, __fpga_ld32(ht + 8)) # L:HT_EA_N_USED ht_set_ea_n_used(h, ht_ea_n_used(h))
    r = ea
    n = size
    while n > 0
      r = __fpga_entry_skip_deleted(r)
      it = __fpga_ib_it_init(h, __fpga_ldv(r + 0)) # L:HE_KEY IB_CYCLE_BY_KEY
      while true
        __fpga_ib_it_next(it)
        if __fpga_ib_it_active_p(it)
          next unless __fpga_obj_eql(__fpga_ldv(r + 0), __fpga_ldv(__fpga_ib_it_entry(it) + 0), h) # L:HE_KEY
          __fpga_stv(__fpga_ib_it_entry(it) + 16, __fpga_ldv(r + 16)) # L:HE_VAL
          size -= 1
          __fpga_st32(h + 8, size) # L:HS_SIZE
          __fpga_entry_delete(r)
        else
          unless w_size == (r - ea) / 32 # L:HASH_ENTRY
            __fpga_ea_set(ea, w_size, __fpga_ldv(r + 0), __fpga_ldv(r + 16)) # L:HE_KEY L:HE_VAL
            __fpga_entry_delete(r)
          end
          __fpga_ib_it_set(it, w_size)
          w_size += 1
        end
        break
      end
      r += 32 # L:HASH_ENTRY
      n -= 1
    end
    __fpga_st32(ht + 8, size) # L:HT_EA_N_USED
    if size <= 16 # L:AR_MAX_SIZE
      __fpga_ht_to_ar(h)
    else
      __fpga_ht_adjust_ea(h, size, ea_capa)
    end
  end

  # 挿入する鍵: 凍っていない String は凍った写しにする
  # C: src/hash.c h_key_for
  def __fpga_h_key_for(h, key)
    if __fpga_tag(key) == 7 && __fpga_tt(__fpga_addr(key)) == 18 && __fpga_frozen_p(__fpga_addr(key)) == false # L:TAG_OBJ L:TT_STRING
      s = __fpga_addr(key)
      key = __fpga_str_new(__fpga_ld32(s + 16), __fpga_ld32(s + 8)) # L:S_PTR L:S_LEN mrb_str_dup
      k = __fpga_addr(key)
      __fpga_st32(k + 4, __fpga_or(__fpga_ld32(k + 4), 2048)) # L:H_FLAGS L:H_FROZEN
    end
    key
  end

  # --- h_* (ar と ht の振り分け)
  # C: src/hash.c h_alloc
  def __fpga_h_alloc
    __fpga_slot(__fpga_addr(__fpga_core(11)), 12) # L:CORE_HASH L:TT_HASH
  end

  # C: src/hash.c h_init
  def __fpga_h_init(h)
    __fpga_ar_init(h, 0, 0, 0, 0)
  end

  # h_free_table は S6
  # C: src/hash.c h_clear
  def __fpga_h_clear(h)
    __fpga_h_init(h)
  end

  # C: src/hash.c h_get
  def __fpga_h_get(h, key)
    __fpga_h_ht_p(h) ? __fpga_ht_get(h, key) : __fpga_ar_get(h, key)
  end

  # C: src/hash.c h_set
  def __fpga_h_set(h, key, val)
    __fpga_h_ht_p(h) ? __fpga_ht_set(h, key, val) : __fpga_ar_set(h, key, val)
  end

  # C: src/hash.c h_delete
  def __fpga_h_delete(h, key)
    __fpga_h_ht_p(h) ? __fpga_ht_delete(h, key) : __fpga_ar_delete(h, key)
  end

  # C: src/hash.c h_shift
  def __fpga_h_shift(h)
    __fpga_h_ht_p(h) ? __fpga_ht_shift(h) : __fpga_ar_shift(h)
  end

  # C: src/hash.c h_rehash
  def __fpga_h_rehash(h)
    if __fpga_h_size(h) == 0
      __fpga_h_clear(h)
    elsif __fpga_h_ht_p(h)
      __fpga_ht_rehash(h)
    else
      __fpga_ar_rehash(h)
    end
  end

  # C: src/hash.c h_replace
  def __fpga_h_replace(h, orig_h)
    size = __fpga_h_size(orig_h)
    if size == 0
      __fpga_h_clear(h)
    elsif __fpga_h_ht_p(orig_h)
      ht0 = __fpga_ld32(orig_h + 12) # L:HS_HSH
      ea_capa = __fpga_ld32(ht0 + 4) # L:HT_EA_CAPA
      ea = __fpga_ea_dup(__fpga_ld32(ht0 + 0), ea_capa) # L:HT_EA
      ht = __fpga_ht_dup(orig_h)
      __fpga_h_ht_set(h, true)
      __fpga_st32(h + 12, ht) # L:HS_HSH
      __fpga_st32(h + 8, size) # L:HS_SIZE
      __fpga_st32(ht + 0, ea) # L:HT_EA
      __fpga_ib_set_bit(h, __fpga_ib_bit(orig_h))
    else
      ea_capa = __fpga_ar_ea_capa(orig_h)
      ea = __fpga_ea_dup(__fpga_ld32(orig_h + 12), ea_capa) # L:HS_HSH
      __fpga_ar_init(h, size, ea, ea_capa, __fpga_ar_ea_n_used(orig_h))
    end
  end

  # --- mrb_hash_* (hash.c の API)
  # C: src/hash.c mrb_hash_new
  def __fpga_hash_new
    __fpga_obj(__fpga_h_alloc)
  end

  # C: src/hash.c mrb_hash_new_capa
  def __fpga_hash_new_capa(capa)
    __fpga_raise(ArgumentError, "hash too big") if capa < 0 || 2147483646 < capa # L:EA_MAX_CAPA
    return __fpga_hash_new if capa == 0
    h = __fpga_h_alloc
    ea = __fpga_ea_resize(0, 0, capa)
    if capa <= 16 # L:AR_MAX_SIZE
      __fpga_ar_init(h, 0, ea, capa, 0)
    else
      __fpga_ht_init(h, 0, ea, capa, 0, __fpga_ib_bit_for(capa))
    end
    __fpga_obj(h)
  end

  # C: src/hash.c hash_modify
  def __fpga_hash_modify(hash)
    __fpga_check_frozen(__fpga_addr(hash))
  end

  # C: src/hash.c hash_default
  def __fpga_hash_default(hash, key)
    f = __fpga_h_flags(__fpga_addr(hash))
    if __fpga_and(f, 1024) > 0 # L:MRB_HASH_DEFAULT
      ifnone = __fpga_iv_get(hash, __fpga_addr(:ifnone)) # RHASH_IFNONE
      return ifnone.call(hash, key) if __fpga_and(f, 2048) > 0 # L:MRB_HASH_PROC_DEFAULT
      return ifnone
    end
    nil
  end

  # C: src/hash.c hash_replace
  def __fpga_hash_replace(hash, orig)
    h = __fpga_addr(hash)
    orig_h = __fpga_addr(orig)
    __fpga_h_replace(h, orig_h)
    name = __fpga_addr(:ifnone)
    if __fpga_and(__fpga_h_flags(orig_h), 1024) > 0 # L:MRB_HASH_DEFAULT
      __fpga_iv_set(hash, name, __fpga_iv_get(orig, name))
    else
      __fpga_iv_remove(hash, name)
    end
    f = __fpga_xor(__fpga_or(__fpga_h_flags(h), 3072), 3072) # MRB_HASH_DEFAULT | MRB_HASH_PROC_DEFAULT
    __fpga_h_set_flags(h, __fpga_or(f, __fpga_and(__fpga_h_flags(orig_h), 3072)))
  end

  # C: src/hash.c mrb_hash_dup
  def __fpga_hash_dup(hash)
    copy = __fpga_hash_new
    __fpga_st32(__fpga_addr(copy) + 0, __fpga_ld32(__fpga_addr(hash) + 0)) # L:H_CLASS copy_h->c
    __fpga_hash_replace(copy, hash)
    copy
  end

  # C: src/hash.c mrb_hash_get
  def __fpga_hash_get(hash, key)
    val = __fpga_h_get(__fpga_addr(hash), key)
    return val unless __fpga_tag(val) == 6 # L:TAG_UNDEF
    return __fpga_hash_default(hash, key) if __fpga_func_basic_p(hash, __fpga_addr(:default), Hash)
    hash.default(key)
  end

  # C: src/hash.c mrb_hash_fetch
  def __fpga_hash_fetch(hash, key, default)
    val = __fpga_h_get(__fpga_addr(hash), key)
    __fpga_tag(val) == 6 ? default : val # L:TAG_UNDEF
  end

  # C: src/hash.c mrb_hash_set
  def __fpga_hash_set(hash, key, val)
    __fpga_hash_modify(hash)
    __fpga_h_set(__fpga_addr(hash), key, val)
  end

  # default_proc の Proc の引数の数を見る (lambda は 2 か、2 を受けられる数)
  # C: src/hash.c hash_set_default_proc
  def __fpga_hash_set_default_proc(hash, proc)
    p = __fpga_addr(proc)
    if __fpga_and(__fpga_ld32(p + 24), 256) > 0 # L:P_FLAGS L:PROC_STRICT
      n = __fpga_proc_arity(p)
      unless n == 2 || (n < 0 && n >= -3)
        n = 0 - n - 1 if n < 0
        __fpga_raisef(TypeError, "default_proc takes two arguments (2 for %d)", [n])
      end
    end
    __fpga_iv_set(hash, __fpga_addr(:ifnone), proc)
    h = __fpga_addr(hash)
    __fpga_h_set_flags(h, __fpga_or(__fpga_h_flags(h), 3072)) # MRB_HASH_PROC_DEFAULT | MRB_HASH_DEFAULT
  end

  # C: src/hash.c mrb_hash_first_key
  def __fpga_hash_first_key(hash)
    h = __fpga_addr(hash)
    return nil if __fpga_h_size(h) == 0
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    e = __fpga_entry_skip_deleted_bounded(e, en)
    e < en ? __fpga_ldv(e + 0) : nil # L:HE_KEY
  end

  # C: src/hash.c mrb_hash_delete_key
  def __fpga_hash_delete_key(hash, key)
    __fpga_hash_modify(hash)
    v = __fpga_h_delete(__fpga_addr(hash), key)
    __fpga_tag(v) == 6 ? nil : v # L:TAG_UNDEF
  end

  # C: src/hash.c mrb_hash_key_p
  def __fpga_hash_key_p(hash, key)
    __fpga_tag(__fpga_h_get(__fpga_addr(hash), key)) == 6 ? false : true # L:TAG_UNDEF
  end

  # C: src/hash.c mrb_hash_merge
  def __fpga_hash_merge(hash1, hash2)
    __fpga_hash_modify(hash1)
    __fpga_ensure_hash_type(hash2)
    h1 = __fpga_addr(hash1)
    h2 = __fpga_addr(hash2)
    return if h1 == h2
    return if __fpga_h_size(h2) == 0
    n = __fpga_h_size(h2)
    e = __fpga_h_ea(h2)
    en = e + __fpga_h_ea_capa(h2) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      c = __fpga_h_check_modified_init(h2)
      if c > 0
        __fpga_h_set(h1, __fpga_ldv(e + 0), __fpga_ldv(e + 16)) # L:HE_KEY L:HE_VAL
        __fpga_h_check_modified_validate(c, h2)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
  end

  # C: src/object.c mrb_ensure_hash_type
  def __fpga_ensure_hash_type(hash)
    __fpga_raisef(TypeError, "%Y cannot be converted to Hash", [hash]) unless __fpga_tag(hash) == 7 && __fpga_tt(__fpga_addr(hash)) == 12 # L:TAG_OBJ L:TT_HASH
    hash
  end

  # C: src/object.c mrb_check_hash_type
  def __fpga_hash_p(hash)
    __fpga_tag(hash) == 7 && __fpga_tt(__fpga_addr(hash)) == 12 # L:TAG_OBJ L:TT_HASH mrb_hash_p
  end

  # --- vm.c の命令
  # OP_HASH: R[a] = {R[a] => R[a+1], ... } (b 組)
  # C: src/vm.c OP_HASH
  def __fpga_op_HASH(a, b, c)
    hash = __fpga_hash_new_capa(b)
    i = a
    lim = a + b * 2
    while i < lim
      __fpga_hash_set(hash, __fpga_reg(i), __fpga_reg(i + 1))
      i += 2
    end
    __fpga_setreg(a, hash)
  end

  # OP_HASHADD: R[a] に R[a+1] => R[a+2], ... (b 組) を足す
  # C: src/vm.c OP_HASHADD
  def __fpga_op_HASHADD(a, b, c)
    hash = __fpga_reg(a)
    __fpga_ensure_hash_type(hash)
    i = a + 1
    lim = a + b * 2 + 1
    while i < lim
      __fpga_hash_set(hash, __fpga_reg(i), __fpga_reg(i + 1))
      i += 2
    end
  end

  # OP_HASHCAT: R[a] に R[a+1] (Hash) を足す (**h)
  # C: src/vm.c OP_HASHCAT
  def __fpga_op_HASHCAT(a, b, c)
    hash = __fpga_reg(a)
    __fpga_ensure_hash_type(hash)
    __fpga_hash_merge(hash, __fpga_reg(a + 1))
  end
end

class Hash
  # C: src/hash.c mrb_hash_equal
  def ==(hash2)
    return true if __fpga_tag(hash2) == 7 && __fpga_addr(hash2) == __fpga_addr(self) # L:TAG_OBJ mrb_obj_equal
    return false unless __fpga_hash_p(hash2)
    return false unless __fpga_h_size(__fpga_addr(self)) == __fpga_h_size(__fpga_addr(hash2))
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    return true if __fpga_recursive_func_p(ci, __fpga_addr(:==), self, hash2)
    h1 = __fpga_addr(self)
    h2 = __fpga_addr(hash2)
    n = __fpga_h_size(h1)
    e = __fpga_h_ea(h1)
    en = e + __fpga_h_ea_capa(h1) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      val2 = __fpga_undef
      c = __fpga_h_check_modified_init(h1)
      if c > 0
        val2 = __fpga_h_get(h2, __fpga_ldv(e + 0)) # L:HE_KEY
        __fpga_h_check_modified_validate(c, h1)
      end
      return false if __fpga_tag(val2) == 6 # L:TAG_UNDEF
      c = __fpga_h_check_modified_init(h1)
      if c > 0
        return false unless __fpga_equal(__fpga_ldv(e + 16), val2) # L:HE_VAL
        __fpga_h_check_modified_validate(c, h1)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    true
  end

  # C: src/hash.c mrb_hash_eql
  def eql?(hash2)
    return true if __fpga_tag(hash2) == 7 && __fpga_addr(hash2) == __fpga_addr(self) # L:TAG_OBJ mrb_obj_equal
    return false unless __fpga_hash_p(hash2)
    return false unless __fpga_h_size(__fpga_addr(self)) == __fpga_h_size(__fpga_addr(hash2))
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    return true if __fpga_recursive_func_p(ci, __fpga_addr(:eql?), self, hash2)
    h1 = __fpga_addr(self)
    h2 = __fpga_addr(hash2)
    n = __fpga_h_size(h1)
    e = __fpga_h_ea(h1)
    en = e + __fpga_h_ea_capa(h1) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      val2 = __fpga_undef
      c = __fpga_h_check_modified_init(h1)
      if c > 0
        val2 = __fpga_h_get(h2, __fpga_ldv(e + 0)) # L:HE_KEY
        __fpga_h_check_modified_validate(c, h1)
      end
      return false if __fpga_tag(val2) == 6 # L:TAG_UNDEF
      c = __fpga_h_check_modified_init(h1)
      if c > 0
        return false unless __fpga_eql(__fpga_ldv(e + 16), val2) # L:HE_VAL
        __fpga_h_check_modified_validate(c, h1)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    true
  end

  # C: src/hash.c mrb_hash_aget
  def [](key)
    __fpga_hash_get(self, key)
  end

  # C: src/hash.c mrb_hash_aset
  def []=(key, val)
    __fpga_hash_set(self, key, val)
    val
  end

  alias store []= # hash.c は []= と store に同じ関数 mrb_hash_aset を置く

  # C: src/hash.c mrb_hash_clear
  def clear
    __fpga_hash_modify(self)
    __fpga_h_clear(__fpga_addr(self))
    self
  end

  # C: src/hash.c mrb_hash_default
  def default(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    f = __fpga_h_flags(__fpga_addr(self))
    if __fpga_and(f, 1024) > 0 # L:MRB_HASH_DEFAULT
      ifnone = __fpga_iv_get(self, __fpga_addr(:ifnone))
      if __fpga_and(f, 2048) > 0 # L:MRB_HASH_PROC_DEFAULT
        return nil if __fpga_alen(args) == 0
        return ifnone.call(self, __fpga_aref(args, 0))
      end
      return ifnone
    end
    nil
  end

  # C: src/hash.c mrb_hash_set_default
  def default=(ifnone)
    __fpga_hash_modify(self)
    __fpga_iv_set(self, __fpga_addr(:ifnone), ifnone)
    h = __fpga_addr(self)
    f = __fpga_xor(__fpga_or(__fpga_h_flags(h), 2048), 2048) # L:MRB_HASH_PROC_DEFAULT
    f = __fpga_tag(ifnone) == 0 ? __fpga_xor(__fpga_or(f, 1024), 1024) : __fpga_or(f, 1024) # L:TAG_NIL L:MRB_HASH_DEFAULT
    __fpga_h_set_flags(h, f)
    ifnone
  end

  # C: src/hash.c mrb_hash_default_proc
  def default_proc
    return __fpga_iv_get(self, __fpga_addr(:ifnone)) if __fpga_and(__fpga_h_flags(__fpga_addr(self)), 2048) > 0 # L:MRB_HASH_PROC_DEFAULT
    nil
  end

  # C: src/hash.c mrb_hash_set_default_proc
  def default_proc=(ifnone)
    __fpga_hash_modify(self)
    has_ifnone = __fpga_tag(ifnone) == 0 ? false : true # L:TAG_NIL
    if has_ifnone && (__fpga_tag(ifnone) == 7 && __fpga_tt(__fpga_addr(ifnone)) == 16) == false # L:TAG_OBJ L:TT_PROC mrb_check_type
      __fpga_raisef(TypeError, "wrong argument type %T (expected Proc)", [ifnone])
    end
    __fpga_iv_set(self, __fpga_addr(:ifnone), ifnone)
    if has_ifnone
      __fpga_hash_set_default_proc(self, ifnone)
    else
      h = __fpga_addr(self)
      __fpga_h_set_flags(h, __fpga_xor(__fpga_or(__fpga_h_flags(h), 3072), 3072)) # MRB_HASH_DEFAULT と MRB_HASH_PROC_DEFAULT を外す
    end
    ifnone
  end

  # C: src/hash.c mrb_hash_delete
  def __delete(key)
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, 0) # L:CI_MID mrb->c->ci->mid = 0
    __fpga_hash_delete_key(self, key)
  end

  # C: src/hash.c mrb_hash_empty_m
  def empty?
    __fpga_h_size(__fpga_addr(self)) == 0
  end

  # C: src/hash.c mrb_hash_has_key
  def has_key?(key)
    __fpga_hash_key_p(self, key)
  end

  alias include? has_key? # hash.c は has_key?、include?、key?、member? に同じ関数 mrb_hash_has_key を置く
  alias key? has_key?
  alias member? has_key?

  # C: src/hash.c mrb_hash_has_value
  def has_value?(val)
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      c = __fpga_h_check_modified_init(h)
      if c > 0
        return true if __fpga_equal(val, __fpga_ldv(e + 16)) # L:HE_VAL
        __fpga_h_check_modified_validate(c, h)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    false
  end

  alias value? has_value? # hash.c は has_value? と value? に同じ関数 mrb_hash_has_value を置く

  # Hash.new (ブロックは default_proc、引数は default)
  # C: src/hash.c mrb_hash_init
  def initialize(*args, &block)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    ifnone_p = __fpga_alen(args) == 1
    ifnone = ifnone_p ? __fpga_aref(args, 0) : nil
    __fpga_hash_modify(self)
    unless __fpga_tag(block) == 0 # L:TAG_NIL
      __fpga_raise_argnum(1, 0, 0) if ifnone_p # mrb_argnum_error(mrb, 1, 0, 0)
      __fpga_hash_set_default_proc(self, block)
      return self
    end
    if ifnone_p && __fpga_tag(ifnone) > 0 # L:TAG_NIL
      h = __fpga_addr(self)
      __fpga_h_set_flags(h, __fpga_or(__fpga_h_flags(h), 1024)) # L:MRB_HASH_DEFAULT
      __fpga_iv_set(self, __fpga_addr(:ifnone), ifnone)
    end
    self
  end

  # C: src/hash.c mrb_hash_init_copy
  def initialize_copy(orig)
    __fpga_ensure_hash_type(orig) # mrb_get_args の H
    __fpga_hash_modify(self)
    __fpga_hash_replace(self, orig) unless __fpga_addr(self) == __fpga_addr(orig)
    self
  end

  alias replace initialize_copy # hash.c は initialize_copy と replace に同じ関数 mrb_hash_init_copy を置く

  # C: src/hash.c mrb_hash_keys
  def keys
    h = __fpga_addr(self)
    ary = [] # mrb_ary_new_capa
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      ary.__fpga_push1(__fpga_ldv(e + 0)) # L:HE_KEY
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    ary
  end

  # C: src/hash.c mrb_hash_size_m
  def size
    __fpga_h_size(__fpga_addr(self))
  end

  alias length size # hash.c は size と length に同じ関数 mrb_hash_size_m を置く

  # C: src/hash.c mrb_hash_shift
  def shift
    h = __fpga_addr(self)
    __fpga_hash_modify(self)
    return nil if __fpga_h_size(h) == 0
    __fpga_h_shift(h) # mrb_assoc_new
  end

  # C: src/hash.c mrb_hash_values
  def values
    h = __fpga_addr(self)
    ary = [] # mrb_ary_new_capa
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      ary.__fpga_push1(__fpga_ldv(e + 16)) # L:HE_VAL
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    ary
  end

  # "{k => v, s: v}"。自分を含む時は "{...}" (MRB_RECURSIVE_UNARY_P)
  # C: src/hash.c mrb_hash_to_s
  def to_s
    ci = __fpga_ld32(__fpga_image(0) + 12) # L:IMG_c L:CTX_CI mrb->c->ci
    __fpga_st32(ci + 4, __fpga_addr(:inspect)) # L:CI_MID mrb->c->ci->mid = MRB_SYM(inspect)
    ret = "{"
    if __fpga_recursive_method_p(ci, __fpga_addr(:inspect), self, nil)
      __fpga_str_cat_str(ret, "...}")
      return ret
    end
    h = __fpga_addr(self)
    i = 0
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      __fpga_str_cat_str(ret, ", ") if i > 0
      key = __fpga_ldv(e + 0) # L:HE_KEY
      if __fpga_tag(key) == 4 # L:TAG_SYM
        __fpga_str_cat_str(ret, __fpga_obj_as_string(key))
        __fpga_str_cat_str(ret, ": ")
      else
        c = __fpga_h_check_modified_init(h)
        if c > 0
          __fpga_str_cat_str(ret, __fpga_inspect(key))
          __fpga_h_check_modified_validate(c, h)
        end
        __fpga_str_cat_str(ret, " => ")
      end
      c = __fpga_h_check_modified_init(h)
      if c > 0
        __fpga_str_cat_str(ret, __fpga_inspect(__fpga_ldv(e + 16))) # L:HE_VAL
        __fpga_h_check_modified_validate(c, h)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
      i += 1
    end
    __fpga_str_cat_str(ret, "}")
  end

  alias inspect to_s # hash.c は to_s と inspect に同じ関数 mrb_hash_to_s を置く

  # C: src/hash.c mrb_hash_rehash
  def rehash
    __fpga_hash_modify(self)
    __fpga_h_rehash(__fpga_addr(self))
    self
  end

  # C: src/hash.c mrb_hash_to_hash
  def to_hash
    self
  end

  # C: src/hash.c mrb_hash_assoc
  def assoc(key)
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      return [__fpga_ldv(e + 0), __fpga_ldv(e + 16)] if __fpga_obj_eql(__fpga_ldv(e + 0), key, h) # L:HE_KEY L:HE_VAL
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    nil
  end

  # C: src/hash.c mrb_hash_rassoc
  def rassoc(value)
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      return [__fpga_ldv(e + 0), __fpga_ldv(e + 16)] if __fpga_obj_eql(__fpga_ldv(e + 16), value, h) # L:HE_KEY L:HE_VAL
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    nil
  end

  # 値が nil の行を消す (compact! の中身)。消した行が無ければ nil
  # C: src/hash.c mrb_hash_compact
  def __compact
    h = __fpga_addr(self)
    size = __fpga_h_size(h)
    dec = 0
    __fpga_hash_modify(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      if __fpga_ld32(e + 16) == 0 # L:HE_VAL L:TAG_NIL mrb_nil_p
        __fpga_entry_delete(e)
        dec += 1
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    return nil if dec == 0
    __fpga_st32(h + 8, size - dec) # L:HS_SIZE
    self
  end

  # パターンの鍵が全部あれば値の配列、無ければ false
  # C: src/hash.c mrb_hash_pat_values
  def __pat_values(keys)
    __fpga_ensure_array_type(keys) # mrb_get_args の A
    klen = __fpga_alen(keys)
    h = __fpga_addr(self)
    result = []
    i = 0
    while i < klen && i < __fpga_alen(keys)
      val = __fpga_h_get(h, __fpga_aref(keys, i))
      return false if __fpga_tag(val) == 6 # L:TAG_UNDEF
      result.__fpga_push1(val)
      i += 1
    end
    result
  end

  # パターンの **rest: keys に無い行の新しい Hash
  # C: src/hash.c mrb_hash_except_keys
  def __except(keys)
    __fpga_ensure_array_type(keys) # mrb_get_args の A
    klen = __fpga_alen(keys)
    result = __fpga_hash_new
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      found = false
      i = 0
      while i < klen && i < __fpga_alen(keys)
        eq = false
        c = __fpga_h_check_modified_init(h)
        if c > 0
          eq = __fpga_equal(__fpga_ldv(e + 0), __fpga_aref(keys, i)) # L:HE_KEY
          __fpga_h_check_modified_validate(c, h)
        end
        if eq
          found = true
          break
        end
        i += 1
      end
      if found == false
        c = __fpga_h_check_modified_init(h)
        if c > 0
          __fpga_hash_set(result, __fpga_ldv(e + 0), __fpga_ldv(e + 16)) # L:HE_KEY L:HE_VAL
          __fpga_h_check_modified_validate(c, h)
        end
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    result
  end

  # --- mruby-hash-ext (src/hash_ext.c)
  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_values_at
  def values_at(*args)
    result = []
    i = 0
    while i < __fpga_alen(args)
      result.__fpga_push1(__fpga_hash_get(self, __fpga_aref(args, i)))
      i += 1
    end
    result
  end

  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_slice
  def slice(*args)
    argc = __fpga_alen(args)
    result = __fpga_hash_new_capa(argc)
    i = 0
    while i < argc
      key = __fpga_aref(args, i)
      val = __fpga_hash_fetch(self, key, __fpga_undef)
      __fpga_hash_set(result, key, val) unless __fpga_tag(val) == 6 # L:TAG_UNDEF
      i += 1
    end
    result
  end

  # args に無い鍵を消し、消した行の Hash を返す (mrb_hash_foreach と slice_bang_i を展開)
  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_slice_bang
  def slice!(*args)
    argc = __fpga_alen(args)
    keep_keys = __fpga_hash_new_capa(argc)
    i = 0
    while i < argc
      __fpga_hash_set(keep_keys, __fpga_aref(args, i), true)
      i += 1
    end
    keys_to_remove = []
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      c = __fpga_h_check_modified_init(h)
      if c > 0
        key = __fpga_ldv(e + 0) # L:HE_KEY
        keys_to_remove.__fpga_push1(key) unless __fpga_hash_key_p(keep_keys, key) # slice_bang_i
        __fpga_h_check_modified_validate(c, h)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    len = __fpga_alen(keys_to_remove)
    removed_hash = __fpga_hash_new_capa(len)
    i = 0
    while i < len
      key = __fpga_ary_ref(keys_to_remove, i)
      __fpga_hash_set(removed_hash, key, __fpga_hash_delete_key(self, key))
      i += 1
    end
    removed_hash
  end

  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_except
  def except(*args)
    result = __fpga_hash_new_capa(__fpga_h_size(__fpga_addr(self)))
    __fpga_hash_merge(result, self)
    i = 0
    while i < __fpga_alen(args)
      __fpga_hash_delete_key(result, __fpga_aref(args, i))
      i += 1
    end
    result
  end

  # 値が val (==) の最初の鍵 (mrb_hash_foreach と hash_key_i を展開)
  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_key
  def key(val)
    h = __fpga_addr(self)
    n = __fpga_h_size(h)
    e = __fpga_h_ea(h)
    en = e + __fpga_h_ea_capa(h) * 32 # L:HASH_ENTRY H_EACH
    while n > 0 && (e = __fpga_entry_skip_deleted_bounded(e, en)) < en
      c = __fpga_h_check_modified_init(h)
      if c > 0
        return __fpga_ldv(e + 0) if __fpga_equal(__fpga_ldv(e + 16), val) # L:HE_KEY L:HE_VAL hash_key_i
        __fpga_h_check_modified_validate(c, h)
      end
      e += 32 # L:HASH_ENTRY
      n -= 1
    end
    nil
  end

  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_merge
  def __merge(*args)
    argc = __fpga_alen(args)
    __fpga_raise(ArgumentError, "wrong number of arguments (given 0, expected 1+)") if argc == 0
    i = 0
    while i < argc
      a = __fpga_aref(args, i)
      __fpga_raisef(TypeError, "no implicit conversion of %C into Hash", [__fpga_obj_class(a)]) unless __fpga_hash_p(a)
      __fpga_hash_merge(self, a)
      i += 1
    end
    self
  end

  # 鍵の値が val と == か (== が C でなければ :send を返し、mrblib が送る)
  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_value_eq
  def __value_eq(key, val)
    v = __fpga_hash_fetch(self, key, __fpga_undef)
    return false if __fpga_tag(v) == 6 # L:TAG_UNDEF
    r = __fpga_equal_in_c(val, v)
    return :send if r < 0
    r == 1
  end

  # Hash[h]、Hash[[[k, v], ...]]、Hash[k, v, ...]
  # C: mrbgems/mruby-hash-ext/src/hash_ext.c hash_s_create
  def self.[](*args)
    argc = __fpga_alen(args)
    klass = __fpga_addr(self)
    if argc == 1
      obj = __fpga_aref(args, 0)
      if __fpga_hash_p(obj)
        hash = __fpga_hash_new
        __fpga_hash_merge(hash, obj)
        __fpga_st32(__fpga_addr(hash) + 0, klass) unless klass == __fpga_image(11) # L:H_CLASS L:IMG_hash_class
        return hash
      end
      if __fpga_tag(obj) == 7 && __fpga_tt(__fpga_addr(obj)) == 17 # L:TAG_OBJ L:TT_ARRAY
        ary_len = __fpga_alen(obj)
        hash = __fpga_hash_new_capa(ary_len)
        i = 0
        while i < ary_len
          elem = __fpga_ary_ref(obj, i)
          unless __fpga_tag(elem) == 7 && __fpga_tt(__fpga_addr(elem)) == 17 # L:TAG_OBJ L:TT_ARRAY
            __fpga_raisef(ArgumentError, "wrong element type %C (expected array)", [__fpga_obj_class(elem)])
          end
          elem_len = __fpga_alen(elem)
          if elem_len == 2
            key = __fpga_ary_ref(elem, 0)
            val = __fpga_ary_ref(elem, 1)
          elsif elem_len == 1
            key = __fpga_ary_ref(elem, 0)
            val = nil
          else
            __fpga_raisef(ArgumentError, "invalid number of elements (%i for 1..2)", [elem_len])
          end
          __fpga_hash_set(hash, key, val)
          i += 1
        end
        __fpga_st32(__fpga_addr(hash) + 0, klass) unless klass == __fpga_image(11) # L:H_CLASS L:IMG_hash_class
        return hash
      end
    end
    __fpga_raise(ArgumentError, "odd number of arguments for Hash") unless __fpga_rem(argc, 2) == 0
    hash = __fpga_hash_new_capa(argc / 2)
    i = 0
    while i < argc
      __fpga_hash_set(hash, __fpga_aref(args, i), __fpga_aref(args, i + 1))
      i += 2
    end
    __fpga_st32(__fpga_addr(hash) + 0, klass) unless klass == __fpga_image(11) # L:H_CLASS L:IMG_hash_class
    hash
  end
end
