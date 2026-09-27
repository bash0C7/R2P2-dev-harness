# firmware: String と Symbol の C の所 (mruby の src/string.c、src/array.c、src/object.c)
class String
  # C: src/string.c mrb_str_to_s
  def to_s
    self
  end

  # C: src/string.c mrb_str_bytesize
  def bytesize
    __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
  end

  # size / length (string.c の mrb_str_size、MRB_UTF8_STRING): 文字の数 = 続きのバイト (10xxxxxx) でないバイトの数
  # C: src/string.c mrb_str_size
  def size
    p = __fpga_ld32(__fpga_addr(self) + 16) # L:S_PTR
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    n = 0
    k = 0
    while k < len
      n += 1 unless __fpga_and(__fpga_ld8(p + k), 192) == 128
      k += 1
    end
    n
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
    a = __fpga_addr(self)
    b = __fpga_addr(str2)
    len1 = __fpga_ld32(a + 8) # L:S_LEN mrb_str_cmp
    len2 = __fpga_ld32(b + 8) # L:S_LEN
    len = len1 < len2 ? len1 : len2
    r = len == 0 ? 0 : __fpga_memcmp(__fpga_ld32(a + 16), __fpga_ld32(b + 16), len) # L:S_PTR
    if r == 0
      return 0 if len1 == len2
      return len1 > len2 ? 1 : -1
    end
    r > 0 ? 1 : -1
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

  # 中身を str2 の中身にする (initialize_copy と replace。mruby は短ければ埋め込み、長ければ共有するが、見える意味は同じ)
  # C: src/string.c mrb_str_replace
  def replace(str2)
    __fpga_ensure_string_type(str2) # mrb_get_args の S
    return self if __fpga_addr(self) == __fpga_addr(str2)
    a = __fpga_addr(self)
    len = __fpga_ld32(__fpga_addr(str2) + 8) # L:S_LEN
    buf = __fpga_alloc(len + 1)
    __fpga_copy(buf, __fpga_ld32(__fpga_addr(str2) + 16), len) # L:S_PTR
    __fpga_st8(buf + len, 0)
    __fpga_st32(a + 16, buf) # L:S_PTR
    __fpga_st32(a + 8, len) # L:S_LEN
    __fpga_st32(a + 12, len) # L:S_CAPA
    self
  end

  alias initialize_copy replace # string.c は initialize_copy と replace に同じ関数 mrb_str_replace を置く

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

  # C: src/string.c mrb_str_getbyte
  def getbyte(i)
    len = __fpga_ld32(__fpga_addr(self) + 8) # L:S_LEN
    i += len if i < 0
    return nil if i < 0 || i >= len
    __fpga_ld8(__fpga_ld32(__fpga_addr(self) + 16) + i) # L:S_PTR
  end
end

class Symbol
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
    base = __fpga_ld32(__fpga_addr(s) + 16) + offset # L:S_PTR
    n = len - offset
    k = 0
    while k + slen <= n # mrb_memsearch
      return k + offset if __fpga_memeq(base + k, sptr, slen)
      k += 1
    end
    -1
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

  # C: src/string.c mrb_str_aref
  def __fpga_str_aref(s, idx, alen)
    unless __fpga_tag(alen) == 6 # L:TAG_UNDEF str_convert_range の STR_CHAR_RANGE
      return __fpga_str_substr(s, __fpga_as_int(idx), __fpga_as_int(alen))
    end
    if __fpga_tag(idx) == 7 && __fpga_tt(__fpga_addr(idx)) == 18 # L:TAG_OBJ L:TT_STRING
      beg = __fpga_str_index_str(s, idx, 0)
      return nil if beg < 0
      return __fpga_str_new(__fpga_ld32(__fpga_addr(idx) + 16), __fpga_ld32(__fpga_addr(idx) + 8)) # L:S_PTR L:S_LEN mrb_str_dup
    end
    if __fpga_tag(idx) == 7 && __fpga_tt(__fpga_addr(idx)) == 19 # L:TAG_OBJ L:TT_RANGE
      bl = __fpga_range_beg_len(idx, __fpga_str_char_len(s), true)
      return nil unless bl
      return __fpga_str_subseq(s, __fpga_aref(bl, 0), __fpga_aref(bl, 1)) # STR_CHAR_RANGE_CORRECTED
    end
    r = __fpga_str_substr(s, __fpga_as_int(idx), 1) # STR_CHAR_RANGE
    return nil if __fpga_tag(r) == 7 && __fpga_ld32(__fpga_addr(r) + 8) == 0 # L:TAG_OBJ L:S_LEN
    r
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

  # 後ろに ptr から len バイトを足す (その場で。容量が足りなければ足りるだけの領域に写す)
  # C: src/string.c mrb_str_cat
  def __fpga_str_cat(s, ptr, len)
    return s if len == 0
    a = __fpga_addr(s)
    n = __fpga_ld32(a + 8) # L:S_LEN
    if n + len > __fpga_ld32(a + 12) # L:S_CAPA
      buf = __fpga_alloc(n + len + 1)
      __fpga_copy(buf, __fpga_ld32(a + 16), n) # L:S_PTR
      __fpga_st32(a + 16, buf) # L:S_PTR
      __fpga_st32(a + 12, n + len) # L:S_CAPA
    end
    buf = __fpga_ld32(a + 16) # L:S_PTR
    __fpga_copy(buf + n, ptr, len)
    __fpga_st8(buf + n + len, 0)
    __fpga_st32(a + 8, n + len) # L:S_LEN
    s
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
    tab = __fpga_image(26) # L:IMG_symtbl
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
