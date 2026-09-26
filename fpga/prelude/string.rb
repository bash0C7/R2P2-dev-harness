# String と表示 (to_s / inspect / puts / print / p / format)。String は Array と同じ形で1語に1バイト、
# 回路の primitive は bytesize / getbyte / __aset / __push / __slice と Symbol#to_s だけ (tools/fpga/isa.rb の PRIMS)。
# 文字は UTF-8 として数える (size、[]、reverse、chars)。大文字小文字は ASCII だけ (ほかの文字があれば止める)。
# 出力は $CONSOLE (console ポート) に1バイトずつ書く。

class String
  def to_s
    self
  end

  def to_str
    self
  end

  def dup
    __slice(0, bytesize)
  end

  def empty?
    bytesize == 0
  end

  # UTF-8 の文字数 (続きのバイト 0b10xxxxxx は数えない)
  def size
    n = 0
    i = 0
    len = bytesize
    while i < len
      n += 1 if (getbyte(i) & 0xC0) != 0x80
      i += 1
    end
    n
  end

  def length
    size
  end

  def ==(other)
    return false unless other.is_a?(String)
    len = bytesize
    return false unless len == other.bytesize
    i = 0
    while i < len
      return false unless getbyte(i) == other.getbyte(i)
      i += 1
    end
    true
  end

  def eql?(other)
    self == other
  end

  def <=>(other)
    return nil unless other.is_a?(String)
    a = bytesize
    b = other.bytesize
    i = 0
    while i < a && i < b
      x = getbyte(i)
      y = other.getbyte(i)
      return x < y ? -1 : 1 unless x == y
      i += 1
    end
    a == b ? 0 : (a < b ? -1 : 1)
  end

  def <(other)
    (self <=> other) < 0
  end

  def >(other)
    (self <=> other) > 0
  end

  # 整数は文字 (UTF-8 に符号化)、ほかは String
  def <<(x)
    if x.is_a?(Integer)
      if x < 0x80
        __push(x)
      elsif x < 0x800
        __push(0xC0 | (x >> 6))
        __push(0x80 | (x & 0x3F))
      elsif x < 0x10000
        __push(0xE0 | (x >> 12))
        __push(0x80 | ((x >> 6) & 0x3F))
        __push(0x80 | (x & 0x3F))
      else
        __push(0xF0 | (x >> 18))
        __push(0x80 | ((x >> 12) & 0x3F))
        __push(0x80 | ((x >> 6) & 0x3F))
        __push(0x80 | (x & 0x3F))
      end
    else
      s = x.to_str
      len = s.bytesize
      i = 0
      while i < len
        __push(s.getbyte(i))
        i += 1
      end
    end
    self
  end

  def concat(x)
    self << x
  end

  def +(other)
    dup << other.to_str
  end

  def *(n)
    r = ""
    n.times { r << self }
    r
  end

  def setbyte(i, b)
    i += bytesize if i < 0
    __aset(i, b & 0xFF)
    b
  end

  def bytes
    r = []
    i = 0
    len = bytesize
    while i < len
      r << getbyte(i)
      i += 1
    end
    r
  end

  def each_byte
    i = 0
    len = bytesize
    while i < len
      yield getbyte(i)
      i += 1
    end
    self
  end

  # 文字 ci 番目のバイト位置 (文字数より先なら bytesize)
  def __byte_at(ci)
    i = 0
    len = bytesize
    while i < len && ci > 0
      i += 1
      i += 1 while i < len && (getbyte(i) & 0xC0) == 0x80
      ci -= 1
    end
    i
  end

  # バイト位置 bi より前の文字数
  def __char_at(bi)
    n = 0
    i = 0
    while i < bi
      n += 1 if (getbyte(i) & 0xC0) != 0x80
      i += 1
    end
    n
  end

  def [](i, len = nil)
    return include?(i) ? i.dup : nil if i.is_a?(String)
    n = size
    i += n if i < 0
    if len.nil?
      return nil if i < 0 || i >= n
      len = 1
    else
      return nil if i < 0 || i > n || len < 0
      len = n - i if i + len > n
    end
    b = __byte_at(i)
    __slice(b, __byte_at(i + len) - b)
  end

  def slice(i, len = nil)
    self[i, len]
  end

  def chars
    r = []
    i = 0
    len = bytesize
    while i < len
      j = i + 1
      j += 1 while j < len && (getbyte(j) & 0xC0) == 0x80
      r << __slice(i, j - i)
      i = j
    end
    r
  end

  def each_char
    chars.each { |c| yield c }
    self
  end

  def ord
    b = getbyte(0)
    return b if b < 0x80
    if b < 0xE0
      ((b & 0x1F) << 6) | (getbyte(1) & 0x3F)
    elsif b < 0xF0
      ((b & 0x0F) << 12) | ((getbyte(1) & 0x3F) << 6) | (getbyte(2) & 0x3F)
    else
      ((b & 0x07) << 18) | ((getbyte(1) & 0x3F) << 12) | ((getbyte(2) & 0x3F) << 6) | (getbyte(3) & 0x3F)
    end
  end

  def reverse
    r = ""
    cs = chars
    i = cs.size - 1
    while i >= 0
      r << cs[i]
      i -= 1
    end
    r
  end

  # 先頭の空白、符号、数字 (_ で区切ってよい) を読む。数字でない所で止まる
  def to_i(base = 10)
    i = 0
    len = bytesize
    i += 1 while i < len && __space?(getbyte(i))
    neg = false
    if i < len && (getbyte(i) == 45 || getbyte(i) == 43)
      neg = getbyte(i) == 45
      i += 1
    end
    n = 0
    while i < len
      c = getbyte(i)
      d = c >= 48 && c <= 57 ? c - 48 : (c >= 97 && c <= 122 ? c - 87 : (c >= 65 && c <= 90 ? c - 55 : 99))
      if d < base
        n = n * base + d
      elsif !(c == 95 && i + 1 < len && getbyte(i + 1) != 95)
        break
      end
      i += 1
    end
    neg ? -n : n
  end

  def __space?(c)
    c == 32 || (c >= 9 && c <= 13)
  end

  def __ascii!
    i = 0
    len = bytesize
    while i < len
      __non_ascii_case_is_not_supported if getbyte(i) >= 0x80
      i += 1
    end
  end

  def upcase
    __ascii!
    r = dup
    i = 0
    len = bytesize
    while i < len
      c = getbyte(i)
      r.setbyte(i, c - 32) if c >= 97 && c <= 122
      i += 1
    end
    r
  end

  def downcase
    __ascii!
    r = dup
    i = 0
    len = bytesize
    while i < len
      c = getbyte(i)
      r.setbyte(i, c + 32) if c >= 65 && c <= 90
      i += 1
    end
    r
  end

  def capitalize
    return "" if empty?
    self[0].upcase + self[1, size - 1].downcase
  end

  def swapcase
    __ascii!
    r = dup
    i = 0
    len = bytesize
    while i < len
      c = getbyte(i)
      r.setbyte(i, c - 32) if c >= 97 && c <= 122
      r.setbyte(i, c + 32) if c >= 65 && c <= 90
      i += 1
    end
    r
  end

  def lstrip
    i = 0
    len = bytesize
    i += 1 while i < len && __space?(getbyte(i))
    __slice(i, len - i)
  end

  def rstrip
    len = bytesize
    len -= 1 while len > 0 && (__space?(getbyte(len - 1)) || getbyte(len - 1) == 0)
    __slice(0, len)
  end

  def strip
    lstrip.rstrip
  end

  def chomp
    len = bytesize
    if len > 0 && getbyte(len - 1) == 10
      len -= 1
      len -= 1 if len > 0 && getbyte(len - 1) == 13
    elsif len > 0 && getbyte(len - 1) == 13
      len -= 1
    end
    __slice(0, len)
  end

  def chop
    return "" if empty?
    self[0, size - 1]
  end

  # バイト位置 from から s が現れる最初のバイト位置 (無ければ nil)
  def __find(s, from)
    n = s.bytesize
    last = bytesize - n
    i = from
    while i <= last
      j = 0
      j += 1 while j < n && getbyte(i + j) == s.getbyte(j)
      return i if j == n
      i += 1
    end
    nil
  end

  def include?(s)
    !__find(s, 0).nil?
  end

  def index(s, start = 0)
    start += size if start < 0
    b = __find(s, __byte_at(start))
    b && __char_at(b)
  end

  def start_with?(s)
    n = s.bytesize
    n <= bytesize && __find(s, 0) == 0
  end

  def end_with?(s)
    n = s.bytesize
    n <= bytesize && !__find(s, bytesize - n).nil?
  end

  # sep が nil か " " なら空白で区切る (前後の空白は捨てる)。ほかは sep で区切り、後ろの空の要素を捨てる
  def split(sep = nil)
    r = []
    len = bytesize
    if sep.nil? || sep == " "
      i = 0
      while i < len
        i += 1 while i < len && __space?(getbyte(i))
        break if i >= len
        j = i
        j += 1 while j < len && !__space?(getbyte(j))
        r << __slice(i, j - i)
        i = j
      end
      return r
    end
    if sep.empty?
      return chars
    end
    i = 0
    while true
      j = __find(sep, i)
      if j.nil?
        r << __slice(i, len - i)
        break
      end
      r << __slice(i, j - i)
      i = j + sep.bytesize
    end
    r.pop while !r.empty? && r[r.size - 1].empty?
    r
  end

  def __pad(width, pad)
    n = width - size
    return "" if n <= 0
    r = ""
    ps = pad.chars
    i = 0
    while i < n
      r << ps[i % ps.size]
      i += 1
    end
    r
  end

  def ljust(width, pad = " ")
    self + __pad(width, pad)
  end

  def rjust(width, pad = " ")
    __pad(width, pad) + self
  end

  def center(width, pad = " ")
    n = width - size
    return dup if n <= 0
    left = n / 2
    __pad(size + left, pad) + self + __pad(n - left + size, pad)
  end

  def sub(from, to)
    b = __find(from, 0)
    return dup if b.nil?
    __slice(0, b) + to + __slice(b + from.bytesize, bytesize - b - from.bytesize)
  end

  def gsub(from, to)
    r = ""
    i = 0
    len = bytesize
    while true
      j = from.empty? ? nil : __find(from, i)
      if j.nil?
        r << __slice(i, len - i)
        break
      end
      r << __slice(i, j - i)
      r << to
      i = j + from.bytesize
    end
    r
  end

  # s の文字の集合に入る文字の数 (CRuby と同じ。範囲 a-z と否定 ^ は止める)
  def count(s)
    set = s.chars
    __char_set_ranges_are_not_supported if set.size > 1 && set[0] == "^"
    k = 1
    while k < set.size - 1
      __char_set_ranges_are_not_supported if set[k] == "-"
      k += 1
    end
    n = 0
    chars.each { |c| n += 1 if set.include?(c) }
    n
  end

  def freeze
    self
  end

  def frozen?
    false
  end

  def hash
    h = 0
    each_byte { |b| h = (h * 31 + b) & 0x3FFFFFFF }
    h
  end

  # CRuby と同じ: 引用符の中で " \ と制御文字をエスケープし、#{ #$ #@ の # も
  def inspect
    r = "\""
    i = 0
    len = bytesize
    while i < len
      c = getbyte(i)
      if c == 34 || c == 92
        r << 92
        r << c
      elsif c == 35 && i + 1 < len && (getbyte(i + 1) == 123 || getbyte(i + 1) == 36 || getbyte(i + 1) == 64)
        r << 92
        r << 35
      elsif c == 10 then r << "\\n"
      elsif c == 9 then r << "\\t"
      elsif c == 13 then r << "\\r"
      elsif c == 27 then r << "\\e"
      elsif c == 7 then r << "\\a"
      elsif c == 8 then r << "\\b"
      elsif c == 11 then r << "\\v"
      elsif c == 12 then r << "\\f"
      elsif c < 32 || c == 127
        r << "\\u"
        r << c.__hex(4, false)
      else
        r.__push(c)
      end
      i += 1
    end
    r << "\""
  end

  def %(args)
    args.is_a?(Array) ? format(self, *args) : format(self, args)
  end
end

class Integer
  # 桁の文字 (0-9、a-z)
  def __digit(d)
    d < 10 ? 48 + d : 87 + d
  end

  def to_s(base = 10)
    return "-2147483648" if self == -2147483648 && base == 10
    return "0" if self == 0
    n = self < 0 ? -self : self
    r = ""
    while n > 0
      r.__push(__digit(n % base))
      n /= base
    end
    r.__push(45) if self < 0
    r.reverse
  end

  def inspect
    to_s
  end

  # 幅 width まで 0 で埋めた 16 進 (upper なら大文字)
  def __hex(width, upper)
    s = to_s(16)
    s = s.upcase if upper
    s.rjust(width, "0")
  end

  def chr
    "" << self
  end

  def to_i
    self
  end

  def to_int
    self
  end

  def ord
    self
  end
end

class Symbol
  def to_sym
    self
  end

  def id2name
    to_s
  end

  def name
    to_s
  end

  def inspect
    ":" + to_s
  end

  def size
    to_s.size
  end

  def length
    size
  end
end

class NilClass
  def to_s
    ""
  end

  def inspect
    "nil"
  end

  def to_a
    []
  end
end

class TrueClass
  def to_s
    "true"
  end

  def inspect
    "true"
  end
end

class FalseClass
  def to_s
    "false"
  end

  def inspect
    "false"
  end
end

class Array
  def inspect
    r = "["
    i = 0
    while i < size
      r << ", " if i > 0
      r << __aget(i).inspect
      i += 1
    end
    r << "]"
  end

  def to_s
    inspect
  end

  def join(sep = "")
    r = ""
    i = 0
    while i < size
      r << sep if i > 0
      x = __aget(i)
      r << (x.is_a?(Array) ? x.join(sep) : x.to_s)
      i += 1
    end
    r
  end
end

class Module
  # クラスの名前は変換器がメソッド表に置く (クラス, NAME_SYM) -> 名前のシンボル
  def name
    __name_sym.to_s
  end

  def to_s
    name
  end

  def inspect
    name
  end
end

class Object
  def to_s
    "#<" + self.class.name + ">"
  end

  def inspect
    to_s
  end

  def ===(other)
    self == other
  end

  def __write(s)
    len = s.bytesize
    i = 0
    while i < len
      $CONSOLE = s.getbyte(i)
      i += 1
    end
  end

  def __puts1(x)
    if x.is_a?(Array)
      __write("\n") if x.empty?
      x.each { |y| __puts1(y) }
      return
    end
    s = x.to_s
    __write(s)
    __write("\n") if s.empty? || s.getbyte(s.bytesize - 1) != 10
  end

  def puts(*args)
    __write("\n") if args.empty?
    args.each { |x| __puts1(x) }
    nil
  end

  def print(*args)
    args.each { |x| __write(x.to_s) }
    nil
  end

  def p(*args)
    args.each do |x|
      __write(x.inspect)
      __write("\n")
    end
    args.size == 0 ? nil : (args.size == 1 ? args[0] : args)
  end

  # %d %i %s %p %x %X %o %b %c %% と、フラグ - 0 + 空白、幅。精度と Float は止める
  def format(fmt, *args)
    r = ""
    k = 0
    i = 0
    len = fmt.bytesize
    while i < len
      c = fmt.getbyte(i)
      if c != 37
        r.__push(c)
        i += 1
        next
      end
      i += 1
      left = false
      zero = false
      plus = false
      space = false
      while i < len
        f = fmt.getbyte(i)
        if f == 45 then left = true
        elsif f == 48 then zero = true
        elsif f == 43 then plus = true
        elsif f == 32 then space = true
        else break
        end
        i += 1
      end
      width = 0
      while i < len && fmt.getbyte(i) >= 48 && fmt.getbyte(i) <= 57
        width = width * 10 + fmt.getbyte(i) - 48
        i += 1
      end
      t = fmt.getbyte(i)
      i += 1
      if t == 37
        r << "%"
        next
      end
      x = args[k]
      k += 1
      s = if t == 100 || t == 105 || t == 117 then x.to_i.to_s
          elsif t == 115 then x.to_s
          elsif t == 112 then x.inspect
          elsif t == 120 then x.to_s(16)
          elsif t == 88 then x.to_s(16).upcase
          elsif t == 111 then x.to_s(8)
          elsif t == 98 then x.to_s(2)
          elsif t == 99 then (x.is_a?(Integer) ? x.chr : x.to_s[0])
          else __format_is_not_supported(t)
          end
      num = t != 115 && t != 112 && t != 99
      if num && x.to_i >= 0
        s = "+" + s if plus
        s = " " + s if space && !plus
      end
      if s.size < width
        if left
          s = s.ljust(width)
        elsif zero && num
          sign = s.getbyte(0) == 45 || s.getbyte(0) == 43 || s.getbyte(0) == 32
          s = sign ? s[0] + s[1, s.size - 1].rjust(width - 1, "0") : s.rjust(width, "0")
        else
          s = s.rjust(width)
        end
      end
      r << s
    end
    r
  end

  def sprintf(fmt, *args)
    format(fmt, *args)
  end
end
