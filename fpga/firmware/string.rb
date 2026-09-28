# firmware: String と Symbol の C の所 (mruby の src/string.c、src/array.c、src/object.c)
class String
  # C: src/string.c mrb_str_to_s
  def to_s
    return __fpga_str_dup(self) unless __fpga_addr(__fpga_obj_class(self)) == __fpga_addr(String) # mrb->string_class
    self
  end

  alias to_str to_s # string.c は to_s と to_str に同じ関数 mrb_str_to_s を置く

  # C: src/string.c mrb_str_bytesize
  def bytesize
    __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
  end

  # size / length (MRB_UTF8_STRING): 文字の数 (mrb_utf8len が文字と読まないバイトは 1 バイトで 1 文字)
  # C: src/string.c mrb_str_size
  def size
    __fpga_str_char_len(self)
  end

  alias length size # string.c は size と length に同じ関数 mrb_str_size を置く

  # + (string.c の mrb_str_plus)
  # C: src/string.c mrb_str_plus_m
  def +(other)
    __fpga_ensure_string_type(other) # mrb_get_args の S
    a = __fpga_addr(self)
    b = __fpga_addr(other)
    la = __fpga_ld32(a + 8) # L:S_LEN
    lb = __fpga_ld32(b + 8)
    buf = __fpga_alloc(la + lb + 1)
    __fpga_copy(buf, __fpga_ld32(a + 16), la) # L:S_PTR
    __fpga_copy(buf + la, __fpga_ld32(b + 16), lb)
    __fpga_str_new(buf, la + lb)
  end

  # C: src/string.c mrb_str_equal_m
  def ==(str2)
    __fpga_str_equal(self, str2)
  end

  # C: src/string.c mrb_str_eql
  def eql?(str2)
    __fpga_tag(str2) == 7 && __fpga_tt(__fpga_addr(str2)) == 18 && __fpga_str_eql(self, str2) # L:TAG_OBJ L:TT_STRING
  end

  # C: src/string.c mrb_str_hash_m
  def hash
    __fpga_str_hash(self)
  end

  # C: src/string.c mrb_str_cmp_m
  def <=>(str2)
    return nil unless __fpga_tag(str2) == 7 && __fpga_tt(__fpga_addr(str2)) == 18 # L:TAG_OBJ L:TT_STRING
    __fpga_str_cmp(self, str2)
  end

  # C: src/string.c mrb_str_empty_p
  def empty?
    __fpga_ld32(__fpga_addr(self) + 8) == 0 # L:S_LEN
  end

  # [] / slice: 整数、(位置, 長さ)、Range、String (文字の位置、MRB_UTF8_STRING)
  # C: src/string.c mrb_str_aref_m
  def [](*args)
    __fpga_check_argc(args, 1, 2) # mrb_get_args の o|o
    __fpga_str_aref(self, __fpga_aref(args, 0), __fpga_alen(args) == 2 ? __fpga_aref(args, 1) : __fpga_undef)
  end

  alias slice [] # string.c は [] と slice に同じ関数 mrb_str_aref_m を置く

  # C: src/string.c mrb_str_byteslice
  def byteslice(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    empty = true
    str_len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    if __fpga_alen(args) == 2
      beg = __fpga_as_int(__fpga_aref(args, 0))
      len = __fpga_as_int(__fpga_aref(args, 1))
    else
      a1 = __fpga_aref(args, 0)
      if __fpga_tag(a1) == 7 && __fpga_tt(__fpga_addr(a1)) == 19 # L:TAG_OBJ L:TT_RANGE
        bl = __fpga_range_beg_len(a1, str_len, true)
        return nil unless bl
        beg = __fpga_aref(bl, 0)
        len = __fpga_aref(bl, 1)
      else
        beg = __fpga_as_int(a1)
        len = 1
        empty = false
      end
    end
    bl = __fpga_str_beg_len(str_len, beg, len)
    return nil unless bl && (empty || (__fpga_aref(bl, 1) == 0) == false)
    __fpga_str_byte_subseq(self, __fpga_aref(bl, 0), __fpga_aref(bl, 1))
  end

  # C: src/string.c mrb_str_include
  def include?(str2)
    __fpga_ensure_string_type(str2) # mrb_get_args の S
    __fpga_str_index_str(self, str2, 0) >= 0
  end

  # C: src/string.c mrb_str_index_m
  def index(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    sub = __fpga_ensure_string_type(__fpga_aref(args, 0)) # S|i
    pos = __fpga_alen(args) == 2 ? __fpga_as_int(__fpga_aref(args, 1)) : 0
    if __fpga_str_single_byte_p(self) # mrb_str_byteindex_m
      len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
      if pos < 0
        pos += len
        return nil if pos < 0
      end
      return nil if pos > len
      return nil unless __fpga_str_valid_encoding_p(sub)
      pos = __fpga_str_index_str(self, sub, pos)
      return pos == -1 ? nil : pos
    end
    if pos < 0
      pos += __fpga_str_char_len(self)
      return nil if pos < 0
    end
    pos = __fpga_str_index_str_by_char(self, sub, pos)
    pos == -1 ? nil : pos
  end

  # C: src/string.c mrb_str_replace
  def replace(str2)
    __fpga_ensure_string_type(str2) # mrb_get_args の S
    __fpga_str_replace(self, str2)
  end

  alias initialize_copy replace # string.c は initialize_copy と replace に同じ関数 mrb_str_replace を置く

  # C: src/string.c mrb_str_init
  def initialize(*args)
    __fpga_check_argc(args, 0, 1) # MRB_ARGS_OPT(1)
    str2 = __fpga_alen(args) == 0 ? __fpga_str_new(0, 0) : __fpga_ensure_string_type(__fpga_aref(args, 0)) # mrb_get_args の |S
    __fpga_str_replace(self, str2)
    self
  end

  # << / concat (mruby-string-ext の str_concat_m): Integer は符号位置の文字 (UTF-8)
  # C: mrbgems/mruby-string-ext/src/string.c str_concat_m
  def <<(obj)
    __fpga_str_concat(self, obj)
    self
  end

  # C: mrbgems/mruby-string-ext/src/string.c str_concat_m
  def concat(obj)
    __fpga_str_concat(self, obj)
    self
  end

  # C: src/string.c mrb_str_inspect
  def inspect
    __fpga_str_escape(self)
  end

  # C: src/string.c mrb_str_intern
  def to_sym
    __fpga_mkval(4, __fpga_intern_str(self)) # L:TAG_SYM
  end

  alias intern to_sym # string.c は intern と to_sym に同じ関数 mrb_str_intern を置く

  # C: src/string.c mrb_str_getbyte
  def getbyte(pos)
    pos = __fpga_as_int(pos) # mrb_get_args の i
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    pos += len if pos < 0
    return nil if pos < 0 || len <= pos
    __fpga_ld8(__fpga_ld32(__fpga_addr(self) + 16) + pos) # L:S_PTR
  end

  # C: src/string.c mrb_str_setbyte
  def setbyte(pos, byte)
    pos = __fpga_as_int(pos) # mrb_get_args の ii
    byte = __fpga_as_int(byte)
    s = __fpga_addr(self)
    len = __fpga_ld32(s + 8) # L:S_LEN
    __fpga_raisef(IndexError, "index %i out of string", [pos]) if pos < 0 - len || len <= pos
    pos += len if pos < 0
    __fpga_str_modify(s)
    byte = __fpga_and(byte, 255)
    __fpga_st8(__fpga_ld32(s + 16) + pos, byte) # L:S_PTR
    byte
  end

  # C: src/string.c mrb_str_bytes
  def bytes
    a = []
    p = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
    pend = p + __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    while p < pend
      a.__fpga_push1(__fpga_ld8(p))
      p += 1
    end
    a
  end

  # C: src/string.c mrb_str_times
  def *(times)
    times = __fpga_as_int(times) # mrb_get_args の i
    __fpga_raise(ArgumentError, "negative argument") if times < 0
    n = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    __fpga_raise(ArgumentError, "argument too big") if __fpga_int_mul_overflow(n, times)
    len = n * times
    str2 = __fpga_str_new_capa(len) # str_new(mrb, 0, len)
    p = __fpga_ld32(__fpga_addr(str2) + 16) # L:S_PTR
    if len > 0
      __fpga_copy(p, __fpga_ld32(__fpga_addr(self) + 16), n) # L:S_PTR
      while n <= __fpga_shr(len, 1)
        __fpga_copy(p + n, p, n)
        n *= 2
      end
      __fpga_copy(p + n, p, len - n)
    end
    __fpga_st8(p + len, 0)
    __fpga_st32(__fpga_addr(str2) + 8, len) # L:S_LEN
    str2
  end

  # C: src/string.c mrb_str_aset_m
  def []=(*args)
    __fpga_check_argc(args, 2, 3) # mrb_get_args の oo|S!
    idx = __fpga_aref(args, 0)
    if __fpga_alen(args) == 2
      replace = __fpga_aref(args, 1)
      alen = __fpga_undef
    else
      alen = __fpga_aref(args, 1)
      replace = __fpga_aref(args, 2)
      __fpga_ensure_string_type(replace) unless __fpga_tag(replace) == 0 # L:TAG_NIL S!
    end
    __fpga_str_aset(self, idx, alen, replace)
    replace
  end

  # C: src/string.c mrb_str_capitalize_bang
  def capitalize!
    __fpga_str_capitalize_bang(self)
  end

  # C: src/string.c mrb_str_capitalize
  def capitalize
    str = __fpga_str_dup(self)
    __fpga_str_capitalize_bang(str)
    str
  end

  # C: src/string.c mrb_str_downcase_bang
  def downcase!
    __fpga_str_downcase_bang(self)
  end

  # C: src/string.c mrb_str_downcase
  def downcase
    str = __fpga_str_dup(self)
    __fpga_str_downcase_bang(str)
    str
  end

  # C: src/string.c mrb_str_upcase_bang
  def upcase!
    __fpga_str_upcase_bang(self)
  end

  # C: src/string.c mrb_str_upcase
  def upcase
    str = __fpga_str_dup(self)
    __fpga_str_upcase_bang(str)
    str
  end

  # C: src/string.c mrb_str_chomp_bang
  def chomp!(*args)
    __fpga_str_chomp_bang(self, args)
  end

  # C: src/string.c mrb_str_chomp
  def chomp(*args)
    str = __fpga_str_dup(self)
    __fpga_str_chomp_bang(str, args)
    str
  end

  # C: src/string.c mrb_str_chop_bang
  def chop!
    __fpga_str_chop_bang(self)
  end

  # C: src/string.c mrb_str_chop
  def chop
    str = __fpga_str_dup(self)
    __fpga_str_chop_bang(str)
    str
  end

  # C: src/string.c mrb_str_reverse_bang
  def reverse!
    __fpga_str_reverse_bang(self)
  end

  # C: src/string.c mrb_str_reverse
  def reverse
    str2 = __fpga_str_dup(self)
    __fpga_str_reverse_bang(str2)
    str2
  end

  # C: src/string.c mrb_str_byteindex_m
  def byteindex(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    sub = __fpga_ensure_string_type(__fpga_aref(args, 0)) # mrb_get_args の S|i
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    if __fpga_alen(args) == 1
      pos = 0
    else
      pos = __fpga_as_int(__fpga_aref(args, 1))
      if pos < 0
        pos += len
        return nil if pos < 0
      end
    end
    return nil if pos > len
    __fpga_str_check_byte_pos(self, pos)
    return nil unless __fpga_str_valid_encoding_p(sub) # str_index_str を見よ
    pos = __fpga_str_index_str(self, sub, pos)
    return nil if pos == -1
    pos
  end

  # C: src/string.c mrb_str_byterindex_m
  def byterindex(*args)
    __fpga_check_argc(args, 1, 2) # MRB_ARGS_ARG(1,1)
    __fpga_str_byterindex_m(self, args)
  end

  # C: src/string.c mrb_str_rindex_m
  def rindex(*args)
    __fpga_check_argc(args, 1, 2) # mrb_get_args の S|i
    return __fpga_str_byterindex_m(self, args) if __fpga_str_single_byte_p(self)
    sub = __fpga_ensure_string_type(__fpga_aref(args, 0))
    if __fpga_alen(args) == 1
      pos = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    else
      pos = __fpga_as_int(__fpga_aref(args, 1))
      if pos >= 0
        pos = __fpga_str_char_to_byte(self, 0, pos)
      else
        p = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
        send = p + __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
        e = send
        while pos < 0 # 負の pos は終わりから文字を数えて戻る。最初の文字に着くのが中に留まる最後の一歩
          return nil if e == p
          e = __fpga_utf8_char_head(p, e - 1, send)
          pos += 1
        end
        pos = e - p
      end
    end
    return nil unless __fpga_str_valid_encoding_p(sub) # str_index_str を見よ
    pos = __fpga_str_char_rindex(self, sub, pos)
    if pos >= 0
      pos = __fpga_str_byte_to_char(self, pos)
      return nil if pos < 0
      return pos
    end
    nil
  end

  # C: src/string.c mrb_str_split_m
  def split(*args)
    __fpga_check_argc(args, 0, 2) # mrb_get_args の |oi
    argc = __fpga_alen(args)
    spat = argc >= 1 ? __fpga_aref(args, 0) : nil
    lim = argc == 2 ? __fpga_as_int(__fpga_aref(args, 1)) : 0
    i = 0
    lim_p = lim > 0 && argc == 2
    str_len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    if argc == 2
      if lim == 1
        return [] if str_len == 0
        return [self]
      end
      i = 1
    end
    awk = false
    if argc == 0 || __fpga_tag(spat) == 0 # L:TAG_NIL
      awk = true
    elsif (__fpga_tag(spat) == 7 && __fpga_tt(__fpga_addr(spat)) == 18) == false # L:TAG_OBJ L:TT_STRING
      __fpga_raise(TypeError, "expected String")
    elsif __fpga_ld32(__fpga_addr(spat) + 8) == 1 && __fpga_ld8(__fpga_ld32(__fpga_addr(spat) + 16)) == 32 # L:S_LEN L:S_PTR ' '
      awk = true
    end
    result = []
    beg = 0
    sp = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
    if awk
      skip = true
      idx = beg
      en = beg
      while idx < str_len
        c = __fpga_ld8(sp + idx)
        idx += 1
        if skip
          if __fpga_isspace(c)
            beg = idx
          else
            en = idx
            skip = false
            break if lim_p && lim <= i
          end
        elsif __fpga_isspace(c)
          result.__fpga_push1(__fpga_str_byte_subseq(self, beg, en - beg))
          skip = true
          beg = idx
          i += 1 if lim_p
        else
          en = idx
        end
      end
    else
      pat_len = __fpga_ld32(__fpga_addr(spat) + 8) # L:S_LEN
      idx = 0
      while idx < str_len
        if pat_len > 0
          en = __fpga_memsearch(__fpga_ld32(__fpga_addr(spat) + 16), pat_len, sp + idx, str_len - idx) # L:S_PTR
          break if en < 0
        else
          en = __fpga_str_char_to_byte(self, idx, 1)
        end
        result.__fpga_push1(__fpga_str_byte_subseq(self, idx, en))
        idx += en + pat_len
        i += 1
        break if lim_p && lim <= i
      end
      beg = idx
    end
    if str_len > 0 && (lim_p || str_len > beg || lim < 0)
      tmp = str_len == beg ? __fpga_str_new(sp, 0) : __fpga_str_byte_subseq(self, beg, str_len - beg)
      result.__fpga_push1(tmp)
    end
    if lim_p == false && lim == 0
      len = __fpga_alen(result)
      while len > 0 && __fpga_ld32(__fpga_addr(__fpga_aref(result, len - 1)) + 8) == 0 # L:S_LEN
        __fpga_st32(__fpga_addr(result) + 8, len - 1) # L:A_LEN mrb_ary_pop
        len = __fpga_alen(result)
      end
    end
    result
  end

  # C: src/string.c mrb_str_to_i
  def to_i(*args)
    __fpga_check_argc(args, 0, 1) # mrb_get_args の |i
    base = __fpga_alen(args) == 1 ? __fpga_as_int(__fpga_aref(args, 0)) : 10
    __fpga_raisef(ArgumentError, "illegal radix %i", [base]) if base < 0 || 36 < base
    __fpga_str_len_to_integer(__fpga_ld32(__fpga_addr(self) + 16), __fpga_ld32(__fpga_addr(self) + 8), base, false) # L:S_PTR L:S_LEN mrb_str_to_integer
  end

  # C: src/string.c sub_replace
  def __sub_replace(replace, pat, found)
    __fpga_ensure_string_type(replace) # mrb_get_args の SSi
    __fpga_ensure_string_type(pat)
    found = __fpga_as_int(found)
    slen = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    __fpga_raise(RuntimeError, "argument out of range") if found < 0 || slen < found
    p = __fpga_ld32(__fpga_addr(replace) + 16) # L:S_PTR
    plen = __fpga_ld32(__fpga_addr(replace) + 8) # L:S_LEN
    match = __fpga_ld32(__fpga_addr(pat) + 16) # L:S_PTR
    mlen = __fpga_ld32(__fpga_addr(pat) + 8) # L:S_LEN
    sptr = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
    result = __fpga_str_new(p, 0)
    i = 0
    while i < plen
      if (__fpga_ld8(p + i) == 92) == false || i + 1 == plen # '\\'
        __fpga_str_cat(result, p + i, 1)
        i += 1
        next
      end
      i += 1
      c = __fpga_ld8(p + i)
      if c == 92 # '\\'
        __fpga_str_cat(result, p + i, 1) # "\\"
      elsif c == 96 # '`'
        __fpga_str_cat(result, sptr, found)
      elsif c == 38 || c == 48 # '&' '0'
        __fpga_str_cat(result, match, mlen)
      elsif c == 39 # '\''
        offset = found + mlen
        __fpga_str_cat(result, sptr + offset, slen - offset) if slen > offset
      elsif c >= 49 && c <= 57 # '1'..'9' 部分の一致は無い (Regexp が無い)
        nil
      else
        __fpga_str_cat(result, p + i - 1, 2)
      end
      i += 1
    end
    result
  end

  # C: src/string.c mrb_str_bytesplice
  def bytesplice(*args)
    argc = __fpga_alen(args)
    if argc == 3
      range1 = __fpga_aref(args, 0)
      replace = __fpga_aref(args, 1)
      range2 = __fpga_aref(args, 2)
      if __fpga_tag(range1) == 3 # L:TAG_INT mrb_get_args の iiS
        len1 = __fpga_as_int(replace)
        replace = __fpga_ensure_string_type(range2)
        return __fpga_str_bytesplice(self, range1, len1, replace, 0, __fpga_ld32(__fpga_addr(replace) + 8)) # L:S_LEN
      end
      __fpga_ensure_string_type(replace)
      bl1 = __fpga_range_beg_len(range1, __fpga_ld32(__fpga_addr(self) + 8), false) # L:S_LEN
      if bl1
        bl2 = __fpga_range_beg_len(range2, __fpga_ld32(__fpga_addr(replace) + 8), false) # L:S_LEN
        return __fpga_str_bytesplice(self, __fpga_aref(bl1, 0), __fpga_aref(bl1, 1), replace, __fpga_aref(bl2, 0), __fpga_aref(bl2, 1)) if bl2
      end
    elsif argc == 5
      idx1 = __fpga_as_int(__fpga_aref(args, 0)) # mrb_get_args の iiSii
      len1 = __fpga_as_int(__fpga_aref(args, 1))
      replace = __fpga_ensure_string_type(__fpga_aref(args, 2))
      idx2 = __fpga_as_int(__fpga_aref(args, 3))
      len2 = __fpga_as_int(__fpga_aref(args, 4))
      return __fpga_str_bytesplice(self, idx1, len1, replace, idx2, len2)
    elsif argc == 2
      range1 = __fpga_aref(args, 0) # mrb_get_args の oS
      replace = __fpga_ensure_string_type(__fpga_aref(args, 1))
      bl1 = __fpga_range_beg_len(range1, __fpga_ld32(__fpga_addr(self) + 8), false) # L:S_LEN
      return __fpga_str_bytesplice(self, __fpga_aref(bl1, 0), __fpga_aref(bl1, 1), replace, 0, __fpga_ld32(__fpga_addr(replace) + 8)) if bl1 # L:S_LEN
    end
    __fpga_raise(ArgumentError, "wrong number of arumgnts")
  end
end

class Symbol
  # C: src/object.c mrb_obj_itself
  def to_sym
    self
  end

  # 名前の String (frozen)
  # C: src/symbol.c sym_name
  def name
    s = __fpga_sym_str(__fpga_addr(self))
    __fpga_st32(__fpga_addr(s) + 4, __fpga_or(__fpga_ld32(__fpga_addr(s) + 4), 2048)) # L:H_FLAGS frozen の bit 11
    s
  end

  # C: src/symbol.c sym_cmp
  def <=>(s2)
    return nil unless __fpga_tag(s2) == 4 # L:TAG_SYM
    return 0 if __fpga_addr(s2) == __fpga_addr(self)
    tab = __fpga_image(1076) # L:IMG_symtbl
    i1 = __fpga_addr(self)
    i2 = __fpga_addr(s2)
    len1 = __fpga_ld32(tab + i1 * 8 + 4)
    len2 = __fpga_ld32(tab + i2 * 8 + 4)
    r = __fpga_memcmp(__fpga_ld32(tab + i1 * 8), __fpga_ld32(tab + i2 * 8), len1 < len2 ? len1 : len2)
    if r == 0
      return 0 if len1 == len2
      return len1 > len2 ? 1 : -1
    end
    r > 0 ? 1 : -1
  end

  # :名前。名前が symbol の literal として書けなければ :"..." (str_escape)
  # C: src/symbol.c sym_inspect
  def inspect
    name = __fpga_sym_str(__fpga_addr(self))
    str = ":"
    __fpga_str_cat_str(str, name)
    p = __fpga_ld32(__fpga_addr(name) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(name) + 8) # L:S_LEN
    unless __fpga_symname_p(p) && __fpga_strlen(p) == len
      str = __fpga_str_escape(str)
      q = __fpga_ld32(__fpga_addr(str) + 16) # L:S_PTR
      __fpga_st8(q, 58) # :
      __fpga_st8(q + 1, 34) # "
    end
    str
  end

  # to_s / id2name (symbol.c): シンボル表の名前から新しい String
  # C: src/symbol.c sym_to_s
  def to_s
    __fpga_sym_str(__fpga_addr(self))
  end
end

class Object
  # C: none (D17)
  def __fpga_strlen(p)
    n = 0
    n += 1 until __fpga_ld8(p + n) == 0
    n
  end

  # C: src/symbol.c is_identchar
  def __fpga_identchar_p(c)
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
  end

  # C: src/symbol.c is_special_global_name
  def __fpga_special_global_name_p(m)
    c = __fpga_ld8(m)
    if c == 126 || c == 42 || c == 36 || c == 63 || c == 33 || c == 64 || c == 47 || c == 92 || c == 59 || c == 44 ||
       c == 46 || c == 61 || c == 58 || c == 60 || c == 62 || c == 34 || c == 38 || c == 96 || c == 39 || c == 43 || c == 48
      m += 1 # ~ * $ ? ! @ / \ ; , . = : < > " & ` ' + 0
    elsif c == 45 # -
      m += 1
      m += 1 if __fpga_identchar_p(__fpga_ld8(m))
    else
      return false unless c >= 48 && c <= 57 # ISDIGIT
      m += 1 while __fpga_ld8(m) >= 48 && __fpga_ld8(m) <= 57
    end
    __fpga_ld8(m) == 0
  end

  # 名前 (NUL で終わるバイト列) が symbol の literal (:名前) として書けるか
  # C: src/symbol.c symname_p
  def __fpga_symname_p(m)
    c = __fpga_ld8(m)
    return false if c == 0
    localid = false
    id = false
    if c == 36 # $
      m += 1
      return true if __fpga_special_global_name_p(m)
      id = true
    elsif c == 64 # @
      m += 1
      m += 1 if __fpga_ld8(m) == 64
      id = true
    elsif c == 60 # <
      m += 1
      if __fpga_ld8(m) == 60
        m += 1
      elsif __fpga_ld8(m) == 61
        m += 1
        m += 1 if __fpga_ld8(m) == 62
      end
    elsif c == 62 # >
      m += 1
      m += 1 if __fpga_ld8(m) == 62 || __fpga_ld8(m) == 61
    elsif c == 61 # =
      m += 1
      if __fpga_ld8(m) == 126
        m += 1
      elsif __fpga_ld8(m) == 61
        m += 1
        m += 1 if __fpga_ld8(m) == 61
      else
        return false
      end
    elsif c == 42 # *
      m += 1
      m += 1 if __fpga_ld8(m) == 42
    elsif c == 33 # !
      m += 1
      m += 1 if __fpga_ld8(m) == 61 || __fpga_ld8(m) == 126
    elsif c == 43 || c == 45 # + -
      m += 1
      m += 1 if __fpga_ld8(m) == 64
    elsif c == 124 # |
      m += 1
      m += 1 if __fpga_ld8(m) == 124
    elsif c == 38 # &
      m += 1
      m += 1 if __fpga_ld8(m) == 38
    elsif c == 94 || c == 47 || c == 37 || c == 126 || c == 96 # ^ / % ~ `
      m += 1
    elsif c == 91 # [
      m += 1
      return false unless __fpga_ld8(m) == 93
      m += 1
      m += 1 if __fpga_ld8(m) == 61
    else
      localid = (c >= 65 && c <= 90) == false # ISUPPER
      id = true
    end
    if id
      c = __fpga_ld8(m)
      return false unless c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) # ISALPHA
      m += 1 while __fpga_identchar_p(__fpga_ld8(m))
      if localid
        c = __fpga_ld8(m)
        m += 1 if c == 33 || c == 63 || c == 61 # ! ? =
      end
    end
    __fpga_ld8(m) == 0
  end

  # C: include/mruby/value.h mrb_undef_value
  def __fpga_undef
    __fpga_mkval(6, 0) # L:TAG_UNDEF
  end

  # mrb_utf8len の表: 先頭のバイトの上 5bit から、その文字のバイト数 (0 は文字の頭でない)
  # C: src/string.c mrb_utf8len
  def __fpga_utf8len(p, e)
    b = __fpga_ld8(p)
    len = __fpga_ld8(__fpga_ld32(__fpga_addr("\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02\x02\x02\x02\x03\x03\x04\x00") + 16) + __fpga_shr(b, 3)) # L:S_PTR mrb_utf8len_table
    return 1 if len > e - p || len == 0
    k = 1
    while k < len
      return 1 unless __fpga_and(__fpga_ld8(p + k), 192) == 128 # utf8_islead
      k += 1
    end
    c1 = len > 1 ? __fpga_ld8(p + 1) : 0
    return 1 if b == 192 || b == 193 # 0xC0 0xC1 overlong
    return 1 if b == 224 && c1 < 160 # 0xE0 overlong
    return 1 if b == 237 && c1 > 159 # 0xED surrogate
    return 1 if b == 240 && c1 < 144 # 0xF0 overlong
    return 1 if b == 244 && c1 > 143 # 0xF4 above U+10FFFF
    return 1 if b >= 245 && b <= 247 # 0xF5..0xF7
    len
  end

  # C: src/string.c search_nonascii
  def __fpga_search_nonascii(p, e)
    while p < e
      return p if __fpga_ld8(p) >= 128
      p += 1
    end
    e
  end

  # [文字の数, 正しい UTF-8 か] (壊れた所で止まる)
  # C: src/string.c utf8_strlen_check
  def __fpga_utf8_strlen_check(p, e)
    len = 0
    while p < e
      np = __fpga_search_nonascii(p, e)
      len += np - p
      break if np == e
      p = np
      while p < e && __fpga_ld8(p) >= 128
        clen = __fpga_utf8len(p, e)
        return [len, false] if clen == 1
        p += clen
        len += 1
      end
    end
    [len, true]
  end

  # 文字列が UTF-8 として正しいか (MRB_STR_CODERANGE の印は持たず、毎回歩く。答えは同じ)
  # C: src/string.c mrb_str_valid_encoding_p
  def __fpga_str_valid_encoding_p(s)
    p = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    __fpga_aref(__fpga_utf8_strlen_check(p, p + __fpga_ld32(__fpga_addr(s) + 8)), 1) # L:S_LEN
  end

  # 1 文字 1 バイト (全部 ASCII) か
  # C: src/string.c mrb_str_single_byte_p
  def __fpga_str_single_byte_p(s)
    p = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    e = p + __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    __fpga_search_nonascii(p, e) == e
  end

  # C: src/string.c mrb_str_char_len
  def __fpga_str_char_len(s)
    p = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    e = p + __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    np = __fpga_search_nonascii(p, e)
    return e - p if np == e
    n = np - p
    while np < e # mrb_utf8_strlen
      if __fpga_ld8(np) < 128
        np += 1
      else
        np += __fpga_utf8len(np, e)
      end
      n += 1
    end
    n
  end

  # 文字の位置 idx (off のバイトから) → バイトの数
  # C: src/string.c mrb_str_char_to_byte
  def __fpga_str_char_to_byte(s, off, idx)
    o = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    e = o + __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    p0 = o + off
    p = p0
    i = 0
    while p < e && i < idx
      if __fpga_ld8(p) < 128
        p += 1
      else
        p += __fpga_utf8len(p, e)
      end
      i += 1
    end
    len = p - p0
    len += 1 if i < idx
    len
  end

  # バイトの位置 → 文字の位置 (文字の途中なら -1)
  # C: src/string.c mrb_str_byte_to_char
  def __fpga_str_byte_to_char(s, bi)
    o = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    return -1 if bi < 0 || len < bi
    e = o + len
    p = o
    pivot = o + bi
    i = 0
    while p < pivot
      if __fpga_ld8(p) < 128
        p += 1
      else
        p += __fpga_utf8len(p, e)
      end
      i += 1
    end
    return -1 unless p == pivot
    i
  end

  # C: src/string.c mrb_str_index
  def __fpga_str_index(s, sptr, slen, offset)
    len = __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    if offset < 0
      offset += len
      return -1 if offset < 0
    end
    return -1 if len - offset < slen
    return offset if slen == 0
    pos = __fpga_memsearch(sptr, slen, __fpga_ld32(__fpga_addr(s) + 16) + offset, len - offset) # L:S_PTR
    return pos if pos < 0
    pos + offset
  end

  # C: src/string.c str_index_str
  def __fpga_str_index_str(s, str2, offset)
    return -1 unless __fpga_str_valid_encoding_p(str2)
    __fpga_str_index(s, __fpga_ld32(__fpga_addr(str2) + 16), __fpga_ld32(__fpga_addr(str2) + 8), offset) # L:S_PTR L:S_LEN
  end

  # C: src/string.c str_index_str_by_char
  def __fpga_str_index_str_by_char(s, sub, pos)
    return -1 unless __fpga_str_valid_encoding_p(sub)
    pos = __fpga_str_char_to_byte(s, 0, pos) if pos > 0
    pos = __fpga_str_index(s, __fpga_ld32(__fpga_addr(sub) + 16), __fpga_ld32(__fpga_addr(sub) + 8), pos) # L:S_PTR L:S_LEN
    pos = __fpga_str_byte_to_char(s, pos) if pos > 0
    pos
  end

  # [beg, len] か false
  # C: src/string.c mrb_str_beg_len
  def __fpga_str_beg_len(str_len, beg, len)
    return false if str_len < beg || len < 0
    if beg < 0
      beg += str_len
      return false if beg < 0
    end
    len = str_len - beg if len > str_len - beg
    len = 0 if len <= 0
    [beg, len]
  end

  # バイトの部分を新しい String に (mruby は長ければ共有するが、見える意味は同じ)
  # C: src/string.c mrb_str_byte_subseq
  def __fpga_str_byte_subseq(s, beg, len)
    __fpga_str_new(__fpga_ld32(__fpga_addr(s) + 16) + beg, len) # L:S_PTR
  end

  # C: src/string.c str_subseq
  def __fpga_str_subseq(s, beg, len)
    beg = __fpga_str_char_to_byte(s, 0, beg)
    len = __fpga_str_char_to_byte(s, beg, len)
    __fpga_str_byte_subseq(s, beg, len)
  end

  # 文字の頭 (p が続きのバイトなら、そこへ届く頭まで戻る)
  # C: src/string.c mrb_utf8_char_head
  def __fpga_utf8_char_head(o, p, e)
    return p if p >= e || (__fpga_and(__fpga_ld8(p), 192) == 128) == false
    back = 1
    while back <= 3 && back <= p - o
      lead = p - back
      unless __fpga_and(__fpga_ld8(lead), 192) == 128
        return __fpga_utf8len(lead, e) > back ? lead : p
      end
      back += 1
    end
    p
  end

  # C: src/string.c str_substr
  def __fpga_str_substr(s, beg, len)
    slen = __fpga_ld32(__fpga_addr(s) + 8) # L:S_LEN
    if __fpga_str_single_byte_p(s)
      bl = __fpga_str_beg_len(slen, beg, len)
      return bl ? __fpga_str_byte_subseq(s, __fpga_aref(bl, 0), __fpga_aref(bl, 1)) : nil
    end
    return nil if len < 0
    o = __fpga_ld32(__fpga_addr(s) + 16) # L:S_PTR
    if beg < 0
      e = o + slen
      p = e
      n = beg
      while n < 0
        return nil if p == o
        p = __fpga_utf8_char_head(o, p - 1, e)
        n += 1
      end
      bbeg = p - o
    else
      bbeg = __fpga_str_char_to_byte(s, 0, beg)
      return nil if bbeg > slen
    end
    blen = __fpga_str_char_to_byte(s, bbeg, len)
    blen = slen - bbeg if blen > slen - bbeg
    __fpga_str_byte_subseq(s, bbeg, blen)
  end

  # [種類, beg, len]。種類は 1 STR_BYTE_RANGE_CORRECTED、2 STR_CHAR_RANGE、3 STR_CHAR_RANGE_CORRECTED、-1 STR_OUT_OF_RANGE
  # C: src/string.c str_convert_range
  def __fpga_str_convert_range(str, idx, alen)
    return [2, __fpga_as_int(idx), __fpga_as_int(alen)] unless __fpga_tag(alen) == 6 # L:TAG_UNDEF
    if __fpga_tag(idx) == 7 && __fpga_tt(__fpga_addr(idx)) == 18 # L:TAG_OBJ L:TT_STRING
      beg = __fpga_str_index_str(str, idx, 0)
      return [-1, 0, 0] if beg < 0
      return [1, beg, __fpga_ld32(__fpga_addr(idx) + 8)] # L:S_LEN
    end
    if __fpga_tag(idx) == 7 && __fpga_tt(__fpga_addr(idx)) == 19 # L:TAG_OBJ L:TT_RANGE
      bl = __fpga_range_beg_len(idx, __fpga_str_char_len(str), true)
      return [-1, 0, 0] unless bl
      return [3, __fpga_aref(bl, 0), __fpga_aref(bl, 1)]
    end
    [2, __fpga_as_int(idx), 1] # mrb_ensure_int_type
  end

  # C: src/string.c mrb_str_aref
  def __fpga_str_aref(str, idx, alen)
    r = __fpga_str_convert_range(str, idx, alen)
    kind = __fpga_aref(r, 0)
    beg = __fpga_aref(r, 1)
    len = __fpga_aref(r, 2)
    return __fpga_str_subseq(str, beg, len) if kind == 3 # STR_CHAR_RANGE_CORRECTED
    if kind == 2 # STR_CHAR_RANGE
      str = __fpga_str_substr(str, beg, len)
      return nil if __fpga_tag(alen) == 6 && __fpga_tag(str) == 7 && __fpga_ld32(__fpga_addr(str) + 8) == 0 # L:TAG_UNDEF L:TAG_OBJ L:S_LEN
      return str
    end
    if kind == 1 # STR_BYTE_RANGE_CORRECTED
      return __fpga_str_dup(idx) if __fpga_tag(idx) == 7 && __fpga_tt(__fpga_addr(idx)) == 18 # L:TAG_OBJ L:TT_STRING
      return __fpga_str_byte_subseq(str, beg, len)
    end
    nil
  end

  # C: src/string.c str_out_of_index
  def __fpga_str_out_of_index(index)
    __fpga_raisef(IndexError, "index %v out of string", [index])
  end

  # pos から end の前までを rep (nil は空) にする
  # C: src/string.c str_replace_partial
  def __fpga_str_replace_partial(src, pos, en, rep)
    str = __fpga_addr(src)
    len = __fpga_ld32(str + 8) # L:S_LEN
    en = len if en > len
    __fpga_str_out_of_index(pos) if pos < 0 || pos > len
    replen = __fpga_tag(rep) == 0 ? 0 : __fpga_ld32(__fpga_addr(rep) + 8) # L:TAG_NIL L:S_LEN
    __fpga_raise(RuntimeError, "string size too big") if __fpga_int_add_overflow(replen, len - (en - pos))
    newlen = replen + len - (en - pos)
    if pos == en && en == len && __fpga_tag(rep) > 0 # L:TAG_NIL 終わりの空の範囲を替えるのは足すこと
      __fpga_str_cat(src, __fpga_ld32(__fpga_addr(rep) + 16), replen) # L:S_PTR
      return src
    end
    __fpga_str_modify(str)
    __fpga_str_resize_capa(str, newlen) if len < newlen
    strp = __fpga_ld32(str + 16) # L:S_PTR
    __fpga_move(strp + newlen - (len - en), strp + en, len - en)
    __fpga_move(strp + pos, __fpga_ld32(__fpga_addr(rep) + 16), replen) if __fpga_tag(rep) > 0 # L:TAG_NIL L:S_PTR
    __fpga_st32(str + 8, newlen) # L:S_LEN
    __fpga_st8(strp + newlen, 0)
    __fpga_str_resize_capa(str, newlen) if len - newlen >= 256 # shrink_threshold
    src
  end

  # C: src/string.c mrb_str_aset
  def __fpga_str_aset(str, idx, alen, replace)
    __fpga_ensure_string_type(replace)
    r = __fpga_str_convert_range(str, idx, alen)
    kind = __fpga_aref(r, 0)
    beg = __fpga_aref(r, 1)
    len = __fpga_aref(r, 2)
    __fpga_raise(IndexError, "string not matched") if kind == -1 # STR_OUT_OF_RANGE
    if kind == 2 # STR_CHAR_RANGE
      __fpga_raisef(IndexError, "negative length %v", [alen]) if len < 0
      charlen = __fpga_str_char_len(str)
      beg += charlen if beg < 0
      __fpga_str_out_of_index(idx) if beg < 0 || beg > charlen
    end
    if kind >= 2 # STR_CHAR_RANGE_CORRECTED
      beg = __fpga_str_char_to_byte(str, 0, beg)
      len = __fpga_str_char_to_byte(str, beg, len)
    end
    __fpga_raise(RuntimeError, "string index too big") if __fpga_int_add_overflow(beg, len)
    __fpga_str_replace_partial(str, beg, beg + len, replace)
  end

  # 書く前の用意: frozen なら FrozenError (firmware の String は buffer を共有しないので、共有を解くことは無い)
  # C: src/string.c mrb_str_modify
  def __fpga_str_modify(s)
    __fpga_check_frozen(s)
  end

  # 容量を capacity バイトにする (mrb_realloc と同じく、前の中身は収まるだけ写す)
  # C: src/string.c resize_capa
  def __fpga_str_resize_capa(s, capacity)
    buf = __fpga_alloc(capacity + 1)
    len = __fpga_ld32(s + 8) # L:S_LEN
    len = capacity if len > capacity
    __fpga_copy(buf, __fpga_ld32(s + 16), len) # L:S_PTR
    __fpga_st8(buf + len, 0)
    __fpga_st32(s + 16, buf) # L:S_PTR
    __fpga_st32(s + 12, capacity) # L:S_CAPA
  end

  # C: src/string.c mrb_str_resize
  def __fpga_str_resize(str, len)
    s = __fpga_addr(str)
    __fpga_str_modify(s)
    slen = __fpga_ld32(s + 8) # L:S_LEN
    unless len == slen
      __fpga_str_resize_capa(s, len) if slen < len || slen - len > 256
      __fpga_st32(s + 8, len) # L:S_LEN
      __fpga_st8(__fpga_ld32(s + 16) + len, 0) # L:S_PTR
    end
    str
  end

  # C: src/string.c mrb_str_new_capa
  def __fpga_str_new_capa(capa)
    s = __fpga_str_new(0, 0)
    __fpga_str_resize_capa(__fpga_addr(s), capa)
    s
  end

  # C: src/string.c mrb_str_dup
  def __fpga_str_dup(str)
    __fpga_str_new(__fpga_ld32(__fpga_addr(str) + 16), __fpga_ld32(__fpga_addr(str) + 8)) # L:S_PTR L:S_LEN
  end

  # 中身を s2 の中身にする (mruby は短ければ埋め込み、長ければ共有するが、見える意味は同じ)
  # C: src/string.c str_replace
  def __fpga_str_replace(str1, str2)
    a = __fpga_addr(str1)
    __fpga_check_frozen(a)
    return str1 if a == __fpga_addr(str2)
    len = __fpga_ld32(__fpga_addr(str2) + 8) # L:S_LEN
    buf = __fpga_alloc(len + 1)
    __fpga_copy(buf, __fpga_ld32(__fpga_addr(str2) + 16), len) # L:S_PTR
    __fpga_st8(buf + len, 0)
    __fpga_st32(a + 16, buf) # L:S_PTR
    __fpga_st32(a + 8, len) # L:S_LEN
    __fpga_st32(a + 12, len) # L:S_CAPA
    str1
  end

  # C: include/mruby.h ISUPPER
  def __fpga_isupper(c)
    c >= 65 && c <= 90
  end

  # C: include/mruby.h ISLOWER
  def __fpga_islower(c)
    c >= 97 && c <= 122
  end

  # C: include/mruby.h TOUPPER
  def __fpga_toupper(c)
    __fpga_islower(c) ? __fpga_and(c, 95) : c # 0x5f
  end

  # C: include/mruby.h TOLOWER
  def __fpga_tolower(c)
    __fpga_isupper(c) ? __fpga_or(c, 32) : c # 0x20
  end

  # C: src/string.c ascii_case_conv
  def __fpga_ascii_case_conv(c, mode, first)
    return __fpga_toupper(c) if mode == 1 # MRB_CASE_UP
    return first ? __fpga_toupper(c) : __fpga_tolower(c) if mode == 2 # MRB_CASE_CAPITALIZE
    return __fpga_isupper(c) ? __fpga_tolower(c) : __fpga_toupper(c) if mode == 3 # MRB_CASE_SWAP
    __fpga_tolower(c)
  end

  # C: src/string.c case_kind_of
  def __fpga_case_kind_of(mode, first)
    return 1 if mode == 1 # MRB_CASE_UP → MRB_CASE_KIND_UPPER
    return first ? 2 : 0 if mode == 2 # MRB_CASE_CAPITALIZE → TITLE か LOWER
    return 3 if mode == 3 # MRB_CASE_SWAP
    return 4 if mode == 4 # MRB_CASE_FOLD
    0 # MRB_CASE_KIND_LOWER
  end

  # o の len の後ろに need バイトの場所 (書く所の番地)
  # C: src/string.c case_out_room
  def __fpga_case_out_room(o, len, need)
    capa = __fpga_ld32(o + 12) # L:S_CAPA
    if capa - len < need
      __fpga_raise(ArgumentError, "string size too big") if __fpga_int_add_overflow(len, need)
      want = len + need
      while capa < want
        if __fpga_int_mul_overflow(capa, 2)
          capa = want
          break
        end
        capa *= 2
      end
      __fpga_st32(o + 8, len) # L:S_LEN
      __fpga_str_resize_capa(o, capa)
    end
    __fpga_ld32(o + 16) + len # L:S_PTR
  end

  # [符号位置, バイトの数]
  # C: src/string.c mrb_utf8_decode
  def __fpga_utf8_decode(p, e)
    c = __fpga_ld8(p)
    n = __fpga_utf8len(p, e)
    if n == 2
      return [__fpga_or(__fpga_shl(__fpga_and(c, 31), 6), __fpga_and(__fpga_ld8(p + 1), 63)), n]
    elsif n == 3
      cp = __fpga_or(__fpga_shl(__fpga_and(c, 15), 12), __fpga_shl(__fpga_and(__fpga_ld8(p + 1), 63), 6))
      return [__fpga_or(cp, __fpga_and(__fpga_ld8(p + 2), 63)), n]
    elsif n == 4
      cp = __fpga_or(__fpga_shl(__fpga_and(c, 7), 18), __fpga_shl(__fpga_and(__fpga_ld8(p + 1), 63), 12))
      cp = __fpga_or(cp, __fpga_shl(__fpga_and(__fpga_ld8(p + 2), 63), 6))
      return [__fpga_or(cp, __fpga_and(__fpga_ld8(p + 3), 63)), n]
    end
    [c, n]
  end

  # 表の言う文字を持つ文字列を変える。答えは横に作り、最後に文字列が中身を取る (変えなければ false)
  # C: src/string.c str_case_convert_utf8
  def __fpga_str_case_convert_utf8(str, mode)
    s = __fpga_addr(str)
    p = __fpga_ld32(s + 16) # L:S_PTR
    pend = p + __fpga_ld32(s + 8) # L:S_LEN
    out = __fpga_str_new_capa(__fpga_ld32(s + 8)) # L:S_LEN
    o = __fpga_addr(out)
    dlen = 0
    modify = false
    first = true
    while p < pend
      d = __fpga_case_out_room(o, dlen, 8) # MRB_UNI_CASE_MAX_BYTES
      if __fpga_ld8(p) < 128
        dend = __fpga_ld32(o + 16) + __fpga_ld32(o + 12) # L:S_PTR L:S_CAPA
        while true
          c = __fpga_ld8(p)
          p += 1
          r = __fpga_ascii_case_conv(c, mode, first)
          first = false
          modify = true unless r == c
          __fpga_st8(d, r)
          d += 1
          break unless p < pend && __fpga_ld8(p) < 128 && d < dend
        end
        dlen = d - __fpga_ld32(o + 16) # L:S_PTR
        next
      end
      src = p
      dec = __fpga_utf8_decode(p, pend)
      cp = __fpga_aref(dec, 0)
      clen = __fpga_aref(dec, 1)
      __fpga_raise(ArgumentError, "input string invalid") if clen == 1
      n = __fpga_uni_case_map(__fpga_case_kind_of(mode, first), cp, d)
      if n == 0 # 写しの無い文字はそのまま
        __fpga_copy(d, src, clen)
        n = clen
      end
      p += clen
      first = false
      modify = true unless n == clen && __fpga_memeq(d, src, n)
      dlen += n
    end
    return false unless modify
    __fpga_st32(o + 8, dlen) # L:S_LEN
    __fpga_st8(__fpga_ld32(o + 16) + dlen, 0) # L:S_PTR
    __fpga_str_replace(str, out)
    true
  end

  # 1 変えた、0 変えない、-1 全部 ASCII (呼んだ側の ASCII の loop に任せる)
  # C: src/string.c mrb_str_case_convert_unicode
  def __fpga_str_case_convert_unicode(str, mode)
    return -1 if __fpga_str_single_byte_p(str) # str_ascii_p
    __fpga_check_frozen(__fpga_addr(str))
    __fpga_str_case_convert_utf8(str, mode) ? 1 : 0
  end

  # C: src/string.c mrb_str_capitalize_bang
  def __fpga_str_capitalize_bang(str)
    uc = __fpga_str_case_convert_unicode(str, 2) # MRB_CASE_CAPITALIZE
    return uc == 1 ? str : nil if uc >= 0
    modify = false
    s = __fpga_addr(str)
    len = __fpga_ld32(s + 8) # L:S_LEN
    __fpga_str_modify(s) # mrb_str_modify_keep_cr
    p = __fpga_ld32(s + 16) # L:S_PTR
    pend = p + len
    return nil if len == 0
    if __fpga_islower(__fpga_ld8(p))
      __fpga_st8(p, __fpga_toupper(__fpga_ld8(p)))
      modify = true
    end
    p += 1
    while p < pend
      if __fpga_isupper(__fpga_ld8(p))
        __fpga_st8(p, __fpga_tolower(__fpga_ld8(p)))
        modify = true
      end
      p += 1
    end
    modify ? str : nil
  end

  # C: src/string.c mrb_str_downcase_bang
  def __fpga_str_downcase_bang(str)
    uc = __fpga_str_case_convert_unicode(str, 0) # MRB_CASE_DOWN
    return uc == 1 ? str : nil if uc >= 0
    modify = false
    s = __fpga_addr(str)
    __fpga_str_modify(s) # mrb_str_modify_keep_cr
    p = __fpga_ld32(s + 16) # L:S_PTR
    pend = p + __fpga_ld32(s + 8) # L:S_LEN
    while p < pend
      if __fpga_isupper(__fpga_ld8(p))
        __fpga_st8(p, __fpga_tolower(__fpga_ld8(p)))
        modify = true
      end
      p += 1
    end
    modify ? str : nil
  end

  # C: src/string.c mrb_str_upcase_bang
  def __fpga_str_upcase_bang(str)
    uc = __fpga_str_case_convert_unicode(str, 1) # MRB_CASE_UP
    return uc == 1 ? str : nil if uc >= 0
    modify = false
    s = __fpga_addr(str)
    __fpga_str_modify(s) # mrb_str_modify_keep_cr
    p = __fpga_ld32(s + 16) # L:S_PTR
    pend = p + __fpga_ld32(s + 8) # L:S_LEN
    while p < pend
      if __fpga_islower(__fpga_ld8(p))
        __fpga_st8(p, __fpga_toupper(__fpga_ld8(p)))
        modify = true
      end
      p += 1
    end
    modify ? str : nil
  end

  # C: src/string.c mrb_str_chomp_bang
  def __fpga_str_chomp_bang(str, args)
    __fpga_check_argc(args, 0, 1) # mrb_get_args の |S
    argc = __fpga_alen(args)
    rs = argc == 1 ? __fpga_ensure_string_type(__fpga_aref(args, 0)) : nil
    s = __fpga_addr(str)
    __fpga_str_modify(s) # mrb_str_modify_keep_cr
    len = __fpga_ld32(s + 8) # L:S_LEN
    p = __fpga_ld32(s + 16) # L:S_PTR
    smart = argc == 0 # smart_chomp
    if smart
      return nil if len == 0
    else
      return nil if len == 0
      return nil unless __fpga_str_valid_encoding_p(rs) # str_index_str を見よ: 文字にならない区切りは何も終えない
      rsp = __fpga_ld32(__fpga_addr(rs) + 16) # L:S_PTR
      rslen = __fpga_ld32(__fpga_addr(rs) + 8) # L:S_LEN
      if rslen == 0
        while len > 0 && __fpga_ld8(p + len - 1) == 10 # '\n'
          len -= 1
          len -= 1 if len > 0 && __fpga_ld8(p + len - 1) == 13 # '\r'
        end
        if len < __fpga_ld32(s + 8) # L:S_LEN
          __fpga_st32(s + 8, len) # L:S_LEN
          __fpga_st8(p + len, 0)
          return str
        end
        return nil
      end
      return nil if rslen > len
      newline = __fpga_ld8(rsp + rslen - 1)
      smart = rslen == 1 && newline == 10 # '\n'
    end
    if smart
      c = __fpga_ld8(p + len - 1)
      if c == 10 # '\n'
        len -= 1
        len -= 1 if len > 0 && __fpga_ld8(p + len - 1) == 13 # '\r'
      elsif c == 13 # '\r'
        len -= 1
      else
        return nil
      end
      __fpga_st32(s + 8, len) # L:S_LEN
      __fpga_st8(p + len, 0)
      return str
    end
    pp = p + len - rslen
    if __fpga_ld8(p + len - 1) == newline && (rslen <= 1 || __fpga_memcmp(rsp, pp, rslen) == 0)
      # バイトが合っても、文字の終わりの一部なら切らない ("あ".chomp("\x82"))
      return nil if __fpga_str_single_byte_p(str) == false && (__fpga_utf8_char_head(p, pp, p + len) == pp) == false
      __fpga_st32(s + 8, len - rslen) # L:S_LEN
      __fpga_st8(p + len - rslen, 0)
      return str
    end
    nil
  end

  # C: src/string.c mrb_str_chop_bang
  def __fpga_str_chop_bang(str)
    s = __fpga_addr(str)
    __fpga_str_modify(s) # mrb_str_modify_keep_cr
    slen = __fpga_ld32(s + 8) # L:S_LEN
    return nil unless slen > 0
    t = __fpga_ld32(s + 16) # L:S_PTR
    len = slen - 1
    len = __fpga_utf8_char_head(t, t + slen - 1, t + slen) - t unless __fpga_str_single_byte_p(str)
    len -= 1 if __fpga_ld8(t + len) == 10 && len > 0 && __fpga_ld8(t + len - 1) == 13 # '\n' '\r'
    __fpga_st32(s + 8, len) # L:S_LEN
    __fpga_st8(t + len, 0)
    str
  end

  # p から e までを逆に (両端を含む)
  # C: src/string.c str_reverse
  def __fpga_str_reverse(p, e)
    while p < e
      c = __fpga_ld8(p)
      __fpga_st8(p, __fpga_ld8(e))
      __fpga_st8(e, c)
      p += 1
      e -= 1
    end
  end

  # C: src/string.c mrb_str_reverse_bang
  def __fpga_str_reverse_bang(str)
    s = __fpga_addr(str)
    utf8_len = __fpga_str_char_len(str)
    len = __fpga_ld32(s + 8) # L:S_LEN
    if utf8_len < 2 # 1 文字か 0 文字はそのまま。それでも壊す呼び出しなので frozen は調べる
      __fpga_check_frozen(s)
      return str
    end
    if utf8_len < len
      __fpga_str_modify(s) # mrb_str_modify_keep_cr
      p = __fpga_ld32(s + 16) # L:S_PTR
      e = p + len
      while p < e # 文字ごとにバイトを逆にしてから、全体を逆に
        clen = __fpga_utf8len(p, e)
        __fpga_str_reverse(p, p + clen - 1)
        p += clen
      end
    elsif len > 1
      __fpga_str_modify(s) # mrb_str_modify_keep_cr
    else
      __fpga_check_frozen(s)
      return str
    end
    p = __fpga_ld32(s + 16) # L:S_PTR bytes:
    __fpga_str_reverse(p, p + len - 1)
    str
  end

  # 文字の途中を指すバイトの位置は IndexError (1 文字 1 バイトの文字列はどこも境目)
  # C: src/string.c mrb_str_check_byte_pos
  def __fpga_str_check_byte_pos(str, pos)
    return if __fpga_str_single_byte_p(str)
    b = __fpga_ld32(__fpga_addr(str) + 16) # L:S_PTR
    p = b + pos
    unless __fpga_utf8_char_head(b, p, b + __fpga_ld32(__fpga_addr(str) + 8)) == p # L:S_LEN
      __fpga_raisef(IndexError, "offset %i does not land on character boundary", [pos])
    end
  end

  # C: src/string.c mrb_str_byterindex_m
  def __fpga_str_byterindex_m(str, args)
    len = __fpga_ld32(__fpga_addr(str) + 8) # L:S_LEN
    sub = __fpga_ensure_string_type(__fpga_aref(args, 0)) # mrb_get_args の S|i
    if __fpga_alen(args) == 1
      pos = len
    else
      pos = __fpga_as_int(__fpga_aref(args, 1))
      if pos < 0
        pos += len
        return nil if pos < 0
      end
      pos = len if pos > len
    end
    __fpga_str_check_byte_pos(str, pos)
    return nil unless __fpga_str_valid_encoding_p(sub) # str_index_str を見よ
    pos = __fpga_str_byterindex(str, sub, pos)
    return nil if pos < 0
    pos
  end

  # 後ろから 1 バイトずつ sub を探す
  # C: src/string.c str_byterindex
  def __fpga_str_byterindex(str, sub, pos)
    len = __fpga_ld32(__fpga_addr(sub) + 8) # L:S_LEN
    slen = __fpga_ld32(__fpga_addr(str) + 8) # L:S_LEN
    return -1 if slen < len
    pos = slen - len if slen - pos < len
    return pos if len == 0
    sbeg = __fpga_ld32(__fpga_addr(str) + 16) # L:S_PTR
    t = __fpga_ld32(__fpga_addr(sub) + 16) # L:S_PTR
    head = __fpga_ld8(t)
    i = pos
    while 0 <= i
      return i if __fpga_ld8(sbeg + i) == head && __fpga_memcmp(sbeg + i, t, len) == 0
      i -= 1
    end
    -1
  end

  # 後ろから文字の境目で sub を探す
  # C: src/string.c str_char_rindex
  def __fpga_str_char_rindex(str, sub, pos)
    len = __fpga_ld32(__fpga_addr(sub) + 8) # L:S_LEN
    slen = __fpga_ld32(__fpga_addr(str) + 8) # L:S_LEN
    return -1 if slen < len
    pos = slen - len if slen - pos < len
    sbeg = __fpga_ld32(__fpga_addr(str) + 16) # L:S_PTR
    send = sbeg + slen
    s = sbeg + pos
    t = __fpga_ld32(__fpga_addr(sub) + 16) # L:S_PTR
    return pos if len == 0
    s = __fpga_utf8_char_head(sbeg, s, send)
    head = __fpga_ld8(t)
    while true
      return s - sbeg if __fpga_ld8(s) == head && send - s >= len && __fpga_memcmp(s, t, len) == 0
      break if s == sbeg
      s = __fpga_utf8_char_head(sbeg, s - 1, send)
    end
    -1
  end

  # x (m バイト) が y (n バイト) の中にある位置 (無ければ -1)
  # C: src/string.c mrb_memsearch
  def __fpga_memsearch(x, m, y, n)
    return -1 if m > n
    return __fpga_memeq(x, y, m) ? 0 : -1 if m == n
    return 0 if m < 1
    k = 0
    while k + m <= n # memchr / memsearch_swar
      return k if __fpga_memeq(y + k, x, m)
      k += 1
    end
    -1
  end

  # C: src/string.c conv_digit
  def __fpga_conv_digit(c)
    return c - 48 if __fpga_isdigit(c)
    return c - 87 if __fpga_islower(c) # c - 'a' + 10
    return c - 55 if __fpga_isupper(c) # c - 'A' + 10
    -1
  end

  # C: src/string.c mrb_str_len_to_integer
  def __fpga_str_len_to_integer(str, len, base, badcheck)
    __fpga_halt if badcheck # badcheck の道 (Kernel#Integer、mruby-kernel-ext) は写していない
    p = str
    pend = str + len
    sign = 1
    n = 0
    return 0 if p == 0
    p += 1 while p < pend && __fpga_isspace(__fpga_ld8(p))
    if __fpga_ld8(p) == 43 # '+'
      p += 1
    elsif __fpga_ld8(p) == 45 # '-'
      p += 1
      sign = 0
    end
    if base <= 0
      if __fpga_ld8(p) == 48 # '0'
        c = __fpga_ld8(p + 1)
        if c == 120 || c == 88 # x X
          base = 16
        elsif c == 98 || c == 66 # b B
          base = 2
        elsif c == 111 || c == 79 # o O
          base = 8
        elsif c == 100 || c == 68 # d D
          base = 10
        else
          base = 8
        end
      elsif base < -1
        __fpga_raisef(ArgumentError, "illegal radix %i", [base]) if base < -9223372036854775807 # -MRB_INT_MAX
        base = 0 - base
      else
        base = 10
      end
    end
    c = __fpga_ld8(p + 1)
    if base == 2
      p += 2 if __fpga_ld8(p) == 48 && (c == 98 || c == 66) # 0b 0B
    elsif base == 8
      p += 2 if __fpga_ld8(p) == 48 && (c == 111 || c == 79) # 0o 0O
    elsif base == 10
      p += 2 if __fpga_ld8(p) == 48 && (c == 100 || c == 68) # 0d 0D
    elsif base == 16
      p += 2 if __fpga_ld8(p) == 48 && (c == 120 || c == 88) # 0x 0X
    elsif base < 2 || 36 < base
      __fpga_raisef(ArgumentError, "illegal radix %i", [base])
    end
    return 0 if p >= pend
    if __fpga_ld8(p) == 48 # 前の 0 を詰める
      p += 1
      while p < pend
        c = __fpga_ld8(p)
        p += 1
        if c == 95 # '_'
          break if p < pend && __fpga_ld8(p) == 95
          next
        end
        unless c == 48
          p -= 1
          break
        end
      end
      p -= 1 if __fpga_ld8(p - 1) == 48
    end
    return 0 if p == pend || __fpga_ld8(p) == 95
    while p < pend
      if __fpga_ld8(p) == 95 # '_'
        p += 1
        if p == pend
          p += 1 # continue (for の p++)
          next
        end
        break if __fpga_ld8(p) == 95
      end
      c = __fpga_conv_digit(__fpga_ld8(p))
      break if c < 0 || c >= base
      __fpga_raisef(RangeError, "string (%s) too big for integer", [__fpga_str_new(str, pend - str)]) if __fpga_int_mul_overflow(n, base) # %l overflow:
      n *= base
      if 9223372036854775807 - c < n # MRB_INT_MAX
        if sign == 0 && 9223372036854775807 - n == c - 1
          n = -9223372036854775807 - 1 # MRB_INT_MIN
          sign = 1
          break
        end
        __fpga_raisef(RangeError, "string (%s) too big for integer", [__fpga_str_new(str, pend - str)]) # %l overflow:
      end
      n += c
      p += 1
    end
    sign == 1 ? n : 0 - n
  end

  # C: src/string.c str_bytesplice
  def __fpga_str_bytesplice(str, idx1, len1, replace, idx2, len2)
    s = __fpga_addr(str)
    rlen = __fpga_ld32(__fpga_addr(replace) + 8) # L:S_LEN
    idx1 += __fpga_ld32(s + 8) if idx1 < 0 # L:S_LEN
    idx2 += rlen if idx2 < 0
    if __fpga_ld32(s + 8) < idx1 || idx1 < 0 || rlen < idx2 || idx2 < 0 # L:S_LEN
      __fpga_raise(IndexError, "index out of string")
    end
    __fpga_raise(IndexError, "negative length") if len1 < 0 || len2 < 0
    len1 = __fpga_ld32(s + 8) - idx1 if __fpga_int_add_overflow(idx1, len1) || __fpga_ld32(s + 8) < idx1 + len1 # L:S_LEN L:S_LEN
    len2 = rlen - idx2 if __fpga_int_add_overflow(idx2, len2) || rlen < idx2 + len2
    rp = __fpga_ld32(__fpga_addr(replace) + 16) # L:S_PTR
    return __fpga_str_cat(str, rp + idx2, len2) if idx1 == __fpga_ld32(s + 8) # L:S_LEN 終わりの空の範囲は足すこと
    __fpga_str_modify(s)
    slen = __fpga_ld32(s + 8) # L:S_LEN
    if len1 >= len2
      __fpga_move(__fpga_ld32(s + 16) + idx1, rp + idx2, len2) # L:S_PTR
      if len1 > len2
        sp = __fpga_ld32(s + 16) # L:S_PTR
        __fpga_move(sp + idx1 + len2, sp + idx1 + len1, slen - (idx1 + len1))
        __fpga_st32(s + 8, slen - (len1 - len2)) # L:S_LEN
      end
    else
      __fpga_str_resize(str, slen + len2 - len1)
      sp = __fpga_ld32(s + 16) # L:S_PTR
      __fpga_move(sp + idx1 + len2, sp + idx1 + len1, slen - (idx1 + len1))
      __fpga_move(sp + idx1, __fpga_ld32(__fpga_addr(replace) + 16) + idx2, len2) # L:S_PTR
    end
    str
  end

  # C: mrbgems/mruby-string-ext/src/string.c str_concat
  def __fpga_str_concat(s, obj)
    if __fpga_tag(obj) == 3 || __fpga_tag(obj) == 5 # L:TAG_INT L:TAG_FLOAT int_chr_utf8
      cp = __fpga_as_int(obj)
      buf = __fpga_alloc(4)
      len = __fpga_utf8_to_buf(buf, cp)
      __fpga_raisef(RangeError, "%v out of char range", [obj]) if len == 0 || (55296 <= cp && cp <= 57343) # 0xD800..0xDFFF
      return __fpga_str_cat(s, buf, len)
    end
    __fpga_str_cat_str(s, __fpga_ensure_string_type(obj))
  end

  # 符号位置を UTF-8 に (バイトの数、範囲の外は 0)
  # C: src/string.c mrb_utf8_to_buf
  def __fpga_utf8_to_buf(buf, cp)
    return 0 if cp < 0
    if cp < 128
      __fpga_st8(buf, cp)
      return 1
    end
    if cp < 2048
      __fpga_st8(buf, 192 + __fpga_shr(cp, 6))
      __fpga_st8(buf + 1, 128 + __fpga_and(cp, 63))
      return 2
    end
    if cp < 65536
      __fpga_st8(buf, 224 + __fpga_shr(cp, 12))
      __fpga_st8(buf + 1, 128 + __fpga_and(__fpga_shr(cp, 6), 63))
      __fpga_st8(buf + 2, 128 + __fpga_and(cp, 63))
      return 3
    end
    return 0 if cp > 1114111 # 0x10FFFF
    __fpga_st8(buf, 240 + __fpga_shr(cp, 18))
    __fpga_st8(buf + 1, 128 + __fpga_and(__fpga_shr(cp, 12), 63))
    __fpga_st8(buf + 2, 128 + __fpga_and(__fpga_shr(cp, 6), 63))
    __fpga_st8(buf + 3, 128 + __fpga_and(cp, 63))
    4
  end

  # inspect の形: "..." の中で " \ #{ #$ #@ を \ で、印字できない文字を \n \t ... か \xNN で。UTF-8 の文字はそのまま
  # C: src/string.c str_escape
  def __fpga_str_escape(str)
    result = "\""
    p = __fpga_ld32(__fpga_addr(str) + 16) # L:S_PTR
    pend = p + __fpga_ld32(__fpga_addr(str) + 8) # L:S_LEN
    hex = __fpga_ld32(__fpga_addr("0123456789ABCDEF") + 16) # L:S_PTR escape_hexmap
    buf = __fpga_alloc(4)
    while p < pend
      clen = __fpga_utf8len(p, pend)
      if clen > 1
        __fpga_str_cat(result, p, clen)
        p += clen
        next
      end
      c = __fpga_ld8(p)
      nx = p + 1 < pend ? __fpga_ld8(p + 1) : 0
      if c == 34 || c == 92 || (c == 35 && p + 1 < pend && (nx == 36 || nx == 64 || nx == 123)) # " \ #$ #@ #{ (IS_EVSTR)
        __fpga_st8(buf, 92)
        __fpga_st8(buf + 1, c)
        __fpga_str_cat(result, buf, 2)
      elsif c >= 32 && c <= 126 # ISPRINT
        __fpga_str_cat(result, p, 1)
      else
        cc = 0
        cc = 110 if c == 10 # \n
        cc = 114 if c == 13 # \r
        cc = 116 if c == 9 # \t
        cc = 102 if c == 12 # \f
        cc = 118 if c == 11 # \v
        cc = 98 if c == 8 # \b
        cc = 97 if c == 7 # \a
        cc = 101 if c == 27 # \e
        __fpga_st8(buf, 92)
        if cc > 0
          __fpga_st8(buf + 1, cc)
          __fpga_str_cat(result, buf, 2)
        else
          __fpga_st8(buf + 1, 120) # x
          __fpga_st8(buf + 2, __fpga_ld8(hex + __fpga_shr(c, 4)))
          __fpga_st8(buf + 3, __fpga_ld8(hex + __fpga_and(c, 15)))
          __fpga_str_cat(result, buf, 4)
        end
      end
      p += 1
    end
    __fpga_str_cat_str(result, "\"")
  end

  # 後ろに ptr から len バイトを足す (その場で。容量が足りなければ倍にしていった容量の領域に写す)。
  # ptr が s 自身の中身を指していてもよい (写した後の同じ位置から読む)
  # C: src/string.c mrb_str_cat
  def __fpga_str_cat(s, ptr, len)
    a = __fpga_addr(s)
    if len == 0 # 足すものが無くても足すことなので、frozen は調べる
      __fpga_check_frozen(a)
      return s
    end
    n = __fpga_ld32(a + 8) # L:S_LEN
    __fpga_raise(ArgumentError, "string size too big") if __fpga_int_add_overflow(n, len)
    total = n + len
    off = -1
    str_addr = __fpga_ld32(a + 16) # L:S_PTR
    if ptr >= str_addr && ptr - str_addr <= n
      off = ptr - str_addr
      if len > n - off
        tmp = __fpga_alloc(len)
        __fpga_copy(tmp, ptr, len)
        ptr = tmp
        off = -1
      end
    end
    __fpga_str_modify(a) # str_modify_cat
    capa = __fpga_ld32(a + 12) # L:S_CAPA
    if capa <= total
      capa = 1 if capa == 0
      capa *= 2 while capa <= total
      __fpga_str_resize_capa(a, capa)
    end
    buf = __fpga_ld32(a + 16) # L:S_PTR
    ptr = buf + off unless off == -1
    __fpga_move(buf + n, ptr, len)
    __fpga_st32(a + 8, total) # L:S_LEN
    __fpga_st8(buf + total, 0)
    s
  end

  # 0、1、-1 (バイトの辞書順、短い方が小さい)
  # C: src/string.c mrb_str_cmp
  def __fpga_str_cmp(str1, str2)
    a = __fpga_addr(str1)
    b = __fpga_addr(str2)
    len1 = __fpga_ld32(a + 8) # L:S_LEN
    len2 = __fpga_ld32(b + 8) # L:S_LEN
    len = len1 < len2 ? len1 : len2
    r = len == 0 ? 0 : __fpga_memcmp(__fpga_ld32(a + 16), __fpga_ld32(b + 16), len) # L:S_PTR
    if r == 0
      return 0 if len1 == len2
      return len1 > len2 ? 1 : -1
    end
    r > 0 ? 1 : -1
  end

  # C: src/string.c mrb_str_equal
  def __fpga_str_equal(str1, str2)
    return false unless __fpga_tag(str2) == 7 && __fpga_tt(__fpga_addr(str2)) == 18 # L:TAG_OBJ L:TT_STRING
    __fpga_str_eql(str1, str2)
  end

  # 長さと中身が同じ
  # C: src/string.c str_eql
  def __fpga_str_eql(str1, str2)
    a = __fpga_addr(str1)
    b = __fpga_addr(str2)
    len = __fpga_ld32(a + 8) # L:S_LEN
    return false unless len == __fpga_ld32(b + 8) # L:S_LEN
    __fpga_memeq(__fpga_ld32(a + 16), __fpga_ld32(b + 16), len) # L:S_PTR
  end

  # FNV-1a (32bit)。hval ^= 1 バイト、hval *= FNV_32_PRIME (0x01000193)
  # C: src/string.c mrb_byte_hash_step
  def __fpga_byte_hash_step(s, len, hval)
    k = 0
    while k < len
      hval = __fpga_and(__fpga_xor(hval, __fpga_ld8(s + k)) * 16777619, 4294967295)
      k += 1
    end
    hval
  end

  # C: src/string.c mrb_str_hash
  def __fpga_str_hash(str)
    s = __fpga_addr(str)
    __fpga_byte_hash_step(__fpga_ld32(s + 16), __fpga_ld32(s + 8), 2166136261) # L:S_PTR L:S_LEN mrb_byte_hash (FNV1_32_INIT)
  end

  # 64bit の値の 8 バイトの mrb_byte_hash。バイトの順は host と R2P2 (どちらも little endian) の記憶の順
  # C: src/string.c mrb_byte_hash
  def __fpga_int64_byte_hash(n)
    hval = 2166136261 # FNV1_32_INIT
    k = 0
    while k < 8
      hval = __fpga_and(__fpga_xor(hval, __fpga_and(__fpga_shr(n, k * 8), 255)) * 16777619, 4294967295)
      k += 1
    end
    hval
  end

  # C: src/string.c mrb_str_cat_str
  def __fpga_str_cat_str(s, t)
    __fpga_str_cat(s, __fpga_ld32(__fpga_addr(t) + 16), __fpga_ld32(__fpga_addr(t) + 8)) # L:S_PTR L:S_LEN
  end

  # シンボル表の名前から新しい String
  # C: src/symbol.c mrb_sym_str
  def __fpga_sym_str(i)
    tab = __fpga_image(1076) # L:IMG_symtbl
    __fpga_str_new(__fpga_ld32(tab + i * 8), __fpga_ld32(tab + i * 8 + 4))
  end

  # 配列の長さと要素を、メソッドを送らずに読む (C の RARRAY_LEN / RARRAY_PTR。firmware の残りの引数に使う)
  # C: include/mruby/array.h RARRAY_LEN
  def __fpga_alen(a)
    __fpga_ld32(__fpga_addr(a) + 8) # L:A_LEN
  end

  # C: include/mruby/array.h RARRAY_PTR
  def __fpga_aref(a, i)
    __fpga_ldv(__fpga_ld32(__fpga_addr(a) + 16) + i * 16) # L:A_PTR L:VALUE
  end
end
