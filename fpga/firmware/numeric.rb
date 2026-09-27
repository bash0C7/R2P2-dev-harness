# firmware: Integer の C の所 (mruby の src/numeric.c)。四則と比較は回路の命令 (整数同士)
class Integer
  # to_s (numeric.c の int_to_s、基数 10)。INT_MIN は符号を反せないので、負の数は負のまま 0 に向けて割る
  def to_s
    x = self
    return "0" if x == 0
    neg = x < 0
    buf = __fpga_alloc(24)
    k = 24
    while x != 0
      d = __fpga_rem(x, 10) # 負の数なら -9..0
      x = (x - d) / 10
      k -= 1
      __fpga_st8(buf + k, neg ? 48 - d : 48 + d)
    end
    if neg
      k -= 1
      __fpga_st8(buf + k, 45)
    end
    __str_new(buf + k, 24 - k)
  end

  # % (numeric.c の int_mod、floor の剰余): 0 に向けて切った剰余を、符号が割る数と違えば割る数を足す
  def %(y)
    x = self
    return x / 0 if y == 0 # ZeroDivisionError (回路の DIV の罠)
    r = __fpga_rem(x, y)
    r += y if r != 0 && (r < 0) != (y < 0)
    r
  end

  def &(y)
    __fpga_and(self, y)
  end

  def |(y)
    __fpga_or(self, y)
  end

  def ^(y)
    __fpga_xor(self, y)
  end

  def !=(y)
    self == y ? false : true
  end

  # 四則と比較のメソッド (numeric.c の int_plus ... int_equal)。self が受け手の式と send から呼ばれる。
  # 局所変数同士にすると回路の命令 (ADD、EQ ...) になる。整数でない相手は V2d / V2e (Float と例外)
  def ==(y)
    return false unless __fpga_tag(y) == 3 # L:TAG_INT
    x = self
    x == y
  end

  # -@ (numeric.c の int_neg)。INT_MIN は桁あふれ (回路の SUB の罠)
  def -@
    x = self
    0 - x
  end

  def +(y)
    x = self
    x + y
  end

  def -(y)
    x = self
    x - y
  end

  def *(y)
    x = self
    x * y
  end

  def /(y)
    x = self
    x / y
  end

  def <(y)
    x = self
    x < y
  end

  def <=(y)
    x = self
    x <= y
  end

  def >(y)
    x = self
    x > y
  end

  def >=(y)
    x = self
    x >= y
  end
end
