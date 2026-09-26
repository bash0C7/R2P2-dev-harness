# Float (docs/spec.md §10「Float (P5b)」)。値はヒープの箱の double で、演算と文字列との変換は回路の primitive
# (tools/fpga/isa.rb の PRIMS: + - * / % ** < <= > >= == <=> -@ to_i nan? to_s と __ で始まるもの)。
# ここはそれを組み合わせる Ruby。CRuby / PicoRuby と同じ結果になるように書く。

class Float
  include Comparable

  INFINITY = 1.0 / 0
  NAN = 0.0 / 0
  EPSILON = 2.220446049250313e-16
  MAX = 1.7976931348623157e+308
  MIN = 2.2250738585072014e-308
  DIG = 15

  def inspect
    to_s
  end

  def to_f
    self
  end

  def to_int
    to_i
  end

  def truncate
    to_i
  end

  def floor(ndigits = 0)
    return __floorf.to_i if ndigits == 0
    __round_digits(ndigits) { |x| x.__floorf }
  end

  def ceil(ndigits = 0)
    return __ceilf.to_i if ndigits == 0
    __round_digits(ndigits) { |x| x.__ceilf }
  end

  # 0.5 は 0 から遠い方へ (CRuby の既定)。ndigits は CRuby の round_half_up と同じ補正をする
  def round(ndigits = 0)
    return __roundf.to_i if ndigits == 0
    return self if nan? || infinite?
    if ndigits > 0
      return self if ndigits >= 17
      s = 10.0**ndigits
      xs = self * s
      f = xs.__roundf
      if self > 0
        f += 1 if (f + 0.5) / s <= self
      elsif (f - 0.5) / s >= self
        f -= 1
      end
      return f / s
    end
    s = 10**(-ndigits)
    (self / s).round * s
  end

  # floor / ceil の桁つき (小さい桁は CRuby と同じく 10**n 倍して丸める)
  def __round_digits(ndigits)
    return self if nan? || infinite? || ndigits >= 17
    if ndigits > 0
      s = 10.0**ndigits
      return yield(self * s) / s
    end
    s = 10**(-ndigits)
    yield(self / s).to_i * s
  end

  def infinite?
    __infinite
  end

  def finite?
    !nan? && __infinite.nil?
  end

  def zero?
    self == 0
  end

  def positive?
    self > 0
  end

  def negative?
    self < 0
  end

  def abs
    self < 0 || (self == 0 && 1.0 / self < 0) ? -self : self
  end

  # CRuby の flodivmod と同じ (C の fmod から)
  def divmod(other)
    y = other.to_f
    raise ZeroDivisionError, "divided by 0" if y == 0
    mod = y.infinite? && !infinite? ? self : __fmod(y)
    div = infinite? && !y.infinite? ? self : ((self - mod) / y).__roundf
    if y * mod < 0
      mod += y
      div -= 1.0
    end
    [div.to_i, mod]
  end

  def div(other)
    raise ZeroDivisionError, "divided by 0" if other == 0
    (self / other).floor
  end

  def modulo(other)
    self % other
  end

  def fdiv(other)
    self / other
  end

  def quo(other)
    self / other
  end

  def eql?(other)
    other.is_a?(Float) && self == other
  end

  def hash
    nan? ? 0 : (self == to_i ? to_i : (self * 1_000_003).to_i)
  end

  def coerce(other)
    [other.to_f, self]
  end

  # CRuby の ruby_float_step と同じ回数と値
  def step(limit, by = 1)
    unit = by.to_f
    last = limit.to_f
    raise ArgumentError, "step can't be 0" if unit == 0
    n = (last - self) / unit
    err = (abs + last.abs + (last - self).abs) / unit.abs * EPSILON
    if unit.infinite?
      yield self if unit > 0 ? self <= last : self >= last
      return self
    end
    return self if n < 0
    err = 0.5 if err > 0.5
    n = (n + err).__floorf + 1
    i = 0
    while i < n
      d = i * unit + self
      d = last if unit >= 0 ? last < d : d < last
      yield d
      i += 1
    end
    self
  end

  # format の %f %e %E %g %G (精度つき)。有限でなければ Inf / -Inf / NaN
  def __format(conv, prec)
    return "NaN" if nan?
    return self > 0 ? "Inf" : "-Inf" if infinite?
    __precision_over_20_is_not_supported if prec > 20
    __fmt(conv, prec)
  end
end

class Integer
  def fdiv(other)
    to_f / other
  end

  def ceil(ndigits = 0)
    return self if ndigits >= 0
    s = 10**(-ndigits)
    -((-self) / s) * s
  end

  def floor(ndigits = 0)
    return self if ndigits >= 0
    s = 10**(-ndigits)
    (self / s) * s
  end

  def round(ndigits = 0)
    return self if ndigits >= 0
    s = 10**(-ndigits)
    r = self % s
    q = self - r
    r * 2 >= s ? q + s : q
  end

  def truncate
    self
  end
end

class String
  # 先頭の空白の後の、Float のリテラルとして読める一番長い部分 (_ は数字の間だけ)。読めなければ 0.0
  def to_f
    t = __float_prefix(false)
    t.nil? ? 0.0 : t.__strtod
  end

  # 整えた Float のリテラル (-?\d+(\.\d+)?(e[-+]?\d+)?) か nil。strict は Float() 用 (全体がリテラルであること)
  def __float_prefix(strict)
    s = strict ? strip : self
    i = 0
    n = s.bytesize
    i += 1 while !strict && i < n && __space?(s.getbyte(i))
    out = ""
    if i < n && (s.getbyte(i) == 45 || s.getbyte(i) == 43)
      out << "-" if s.getbyte(i) == 45
      i += 1
    end
    digits, i = __digits(s, i, n)
    return nil if digits.empty?
    out << digits
    if i + 1 < n && s.getbyte(i) == 46
      frac, j = __digits(s, i + 1, n)
      unless frac.empty?
        out << "." << frac
        i = j
      end
    end
    if i + 1 < n && (s.getbyte(i) == 101 || s.getbyte(i) == 69)
      j = i + 1
      sign = ""
      if s.getbyte(j) == 45 || s.getbyte(j) == 43
        sign = "-" if s.getbyte(j) == 45
        j += 1
      end
      exp, k = __digits(s, j, n)
      unless exp.empty?
        out << "e" << sign << exp
        i = k
      end
    end
    return nil if strict && i != n
    out
  end

  # s の i 番目からの数字 (_ は数字の間だけ)。[数字, 次の位置]
  def __digits(s, i, n)
    d = ""
    while i < n
      c = s.getbyte(i)
      if c >= 48 && c <= 57
        d << c.chr
      elsif c == 95 && !d.empty? && i + 1 < n && s.getbyte(i + 1) >= 48 && s.getbyte(i + 1) <= 57
        # 数字の間の _
      else
        break
      end
      i += 1
    end
    [d, i]
  end
end

class Object
  def Float(x)
    return x if x.is_a?(Float)
    return x.to_f if x.is_a?(Integer)
    raise TypeError, "can't convert nil into Float" if x.nil?
    t = x.is_a?(String) ? x.__float_prefix(true) : nil
    raise ArgumentError, "invalid value for Float(): #{x.inspect}" if t.nil?
    t.__strtod
  end
end

module Math
  PI = 3.141592653589793
  E = 2.718281828459045

  class DomainError < ArgumentError; end

  def self.__f(x, name)
    raise TypeError, "can't convert #{x.nil? ? 'nil' : x.class} into Float" unless x.is_a?(Integer) || x.is_a?(Float)
    x.to_f
  end

  def self.__domain(ok, name)
    raise DomainError, "Numerical argument is out of domain - #{name}" unless ok
  end

  def self.sqrt(x)
    x = __f(x, "sqrt")
    __domain(!(x < 0), "sqrt")
    x.__math(0)
  end

  def self.sin(x) = __f(x, "sin").__math(1)
  def self.cos(x) = __f(x, "cos").__math(2)
  def self.tan(x) = __f(x, "tan").__math(3)

  def self.asin(x)
    x = __f(x, "asin")
    __domain(!(x < -1 || x > 1), "asin")
    x.__math(4)
  end

  def self.acos(x)
    x = __f(x, "acos")
    __domain(!(x < -1 || x > 1), "acos")
    x.__math(5)
  end

  def self.atan(x) = __f(x, "atan").__math(6)
  def self.exp(x) = __f(x, "exp").__math(7)

  def self.log(x, base = nil)
    x = __f(x, "log")
    __domain(!(x < 0), "log")
    r = x.__math(8)
    base.nil? ? r : r / log(base)
  end

  def self.log2(x)
    x = __f(x, "log2")
    __domain(!(x < 0), "log2")
    x.__math(9)
  end

  def self.log10(x)
    x = __f(x, "log10")
    __domain(!(x < 0), "log10")
    x.__math(10)
  end

  def self.sinh(x) = __f(x, "sinh").__math(11)
  def self.cosh(x) = __f(x, "cosh").__math(12)
  def self.tanh(x) = __f(x, "tanh").__math(13)
  def self.atan2(y, x) = __f(y, "atan2").__atan2(__f(x, "atan2"))
  def self.hypot(x, y) = __f(x, "hypot").__hypot(__f(y, "hypot"))

end
