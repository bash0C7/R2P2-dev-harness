# frozen_string_literal: true

# Float と10進の変換を多倍長の整数だけで正確に (fpga/rtl/mrb_core.sv の f_to_s / f_fmt / f_strtod と同じアルゴリズム)。
# to_s は Ruby の Float#to_s、fmt は C の printf の %.<prec>f/e/E/g/G (PicoRuby と同じく正確に丸める。CRuby の format は
# まれに違う)、strtod は一番近い double (0.5 は偶数へ)。どれも double を bit (64bit の Integer) で受け渡す
module FpgaFloat
  module_function

  def parts(bits)
    ex = (bits >> 52) & 0x7FF
    fr = bits & ((1 << 52) - 1)
    ex == 0 ? [fr, -1074] : [fr | (1 << 52), ex - 1075]
  end

  # 最短で元に戻る10進の桁 (Burger & Dybvig の free-format。境界は f が偶数なら含む)。[digits(String), decpt]
  def shortest(bits)
    f, e = parts(bits)
    even = f.even?
    if e >= 0
      if f != (1 << 52)
        r = f << (e + 1); s = 2; mp = 1 << e; mm = 1 << e
      else
        r = f << (e + 2); s = 4; mp = 1 << (e + 1); mm = 1 << e
      end
    elsif e == -1074 || f != (1 << 52)
      r = f << 1; s = 1 << (1 - e); mp = 1; mm = 1
    else
      r = f << 2; s = 1 << (2 - e); mp = 2; mm = 1
    end
    # k: 10^(k-1) <= v < 10^k となるように s か r を 10 倍する
    k = 0
    while (even ? r + mp >= s : r + mp > s)
      s *= 10
      k += 1
    end
    while (even ? (r + mp) * 10 < s : (r + mp) * 10 <= s)
      r *= 10; mp *= 10; mm *= 10
      k -= 1
    end
    digs = +""
    loop do
      r *= 10; mp *= 10; mm *= 10
      d = r / s
      r %= s
      tc1 = even ? r <= mm : r < mm
      tc2 = even ? r + mp >= s : r + mp > s
      if !tc1 && !tc2
        digs << (48 + d).chr
        next
      end
      if tc1 && !tc2 then digs << (48 + d).chr
      elsif !tc1 && tc2 then digs << (49 + d).chr
      else digs << (r * 2 < s || (r * 2 == s && d.even?) ? 48 + d : 49 + d).chr
      end
      break
    end
    [digs, k]
  end

  def to_s(bits)
    ex = (bits >> 52) & 0x7FF
    fr = bits & ((1 << 52) - 1)
    neg = bits[63] == 1
    return "NaN" if ex == 0x7FF && fr != 0
    return neg ? "-Infinity" : "Infinity" if ex == 0x7FF
    return neg ? "-0.0" : "0.0" if (bits & ((1 << 63) - 1)).zero?
    digs, decpt = shortest(bits & ((1 << 63) - 1))
    n = digs.size
    out = neg ? +"-" : +""
    if decpt > 0 && (decpt <= 15 || (decpt == 16 && n > decpt))
      out << (n <= decpt ? digs + "0" * (decpt - n) + ".0" : digs[0, decpt] + "." + digs[decpt..])
    elsif decpt <= 0 && decpt > -4
      out << "0." << "0" * -decpt << digs
    else
      e = decpt - 1
      out << digs[0] << "." << (n > 1 ? digs[1..] : "0") << (e < 0 ? "e-" : "e+") << format("%02d", e.abs)
    end
    out
  end

  # 正の有理数 num/den を整数に丸める (0.5 は偶数へ)
  def round_even(num, den)
    q, r = num.divmod(den)
    q += 1 if r * 2 > den || (r * 2 == den && q.odd?)
    q
  end

  # 有限の正の double を 10^p 倍して偶数丸め (整数)
  def scaled(bits, p)
    f, e = parts(bits)
    num = f
    den = 1
    e >= 0 ? num <<= e : den <<= -e
    p >= 0 ? num *= 10**p : den *= 10**-p
    round_even(num, den)
  end

  # 10^(k-1) <= v < 10^k の k (v > 0)
  def decexp(bits)
    f, e = parts(bits)
    num = e >= 0 ? f << e : f
    den = e >= 0 ? 1 : 1 << -e
    k = 0
    while num >= den
      den *= 10
      k += 1
    end
    while num * 10 < den
      num *= 10
      k -= 1
    end
    k
  end

  def fmt_f(bits, prec)
    q = scaled(bits, prec).to_s
    q = "0" * (prec + 1 - q.size) + q if q.size <= prec
    prec.zero? ? q : q[0, q.size - prec] + "." + q[-prec..]
  end

  # %e: 仮数の桁 (prec + 1 桁) と指数
  def e_digits(bits, prec)
    return ["0" * (prec + 1), 0] if bits.zero?
    k = decexp(bits)
    q = scaled(bits, prec + 1 - k)
    if q >= 10**(prec + 1)
      k += 1
      q = scaled(bits, prec + 1 - k)
    end
    [q.to_s, k - 1]
  end

  def fmt_e(bits, prec, upper)
    d, x = e_digits(bits, prec)
    m = prec.zero? ? d : d[0] + "." + d[1..]
    m + (upper ? "E" : "e") + (x < 0 ? "-" : "+") + format("%02d", x.abs)
  end

  def fmt_g(bits, prec, upper)
    p = prec.zero? ? 1 : prec
    _, x = e_digits(bits, p - 1)
    s = if x < -4 || x >= p then fmt_e(bits, p - 1, upper)
        else fmt_f(bits, p - 1 - x)
        end
    # 小数の末尾の 0 と小数点を消す (指数の前まで)
    m, ex = s.split(/(?=[eE])/)
    m = m.sub(/0+\z/, "").sub(/\.\z/, "") if m.include?(".")
    ex ? m + ex : m
  end

  def fmt(bits, conv, prec)
    neg = bits[63] == 1
    a = bits & ((1 << 63) - 1)
    s = case conv
        when "f" then fmt_f(a, prec)
        when "e", "E" then fmt_e(a, prec, conv == "E")
        else fmt_g(a, prec, conv == "G")
        end
    neg ? "-" + s : s
  end

  # 10進のリテラル (-?\d+(\.\d+)?([eE][-+]?\d+)?) を一番近い double に (0.5 は偶数へ)。double の bit
  def strtod(text)
    m = text.match(/\A(-?)(\d+)(?:\.(\d+))?(?:[eE]([-+]?\d+))?\z/)
    neg = m[1] == "-"
    d = (m[2] + (m[3] || "")).to_i
    e10 = (m[4] || "0").to_i - (m[3] || "").size
    sign = neg ? 1 << 63 : 0
    return sign if d.zero?
    # 値は 10^(nd+e10) より小さく 10^(nd+e10-1) 以上 (nd は桁数)。回路と同じ所で打ち切る
    nd = d.to_s.size
    return sign if nd + e10 < -324
    return sign | (0x7FF << 52) if nd + e10 > 310
    num = d
    den = 1
    e10 >= 0 ? num *= 10**e10 : den *= 10**-e10
    # num/den = q * 2^b、q は 53bit (2^52 <= q < 2^53)。最小の指数 -1074 より下は非正規化
    b = num.bit_length - den.bit_length - 53
    b += 1 while (num << [-b, 0].max) >= (den << [b, 0].max) << 53
    b -= 1 while (num << [-b, 0].max) < (den << [b, 0].max) << 52
    b = -1074 if b < -1074
    q = round_even(num << [-b, 0].max, den << [b, 0].max)
    if q == 1 << 53
      q >>= 1
      b += 1
    end
    return sign | (0x7FF << 52) if b + 52 > 1023
    if q < (1 << 52) # 非正規化
      sign | q
    else
      sign | ((b + 1075) << 52) | (q & ((1 << 52) - 1))
    end
  end
end
