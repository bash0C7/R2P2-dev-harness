# FPGA の CPU コアで、プログラムの前に置いて一緒に変換する組み込みメソッド (mruby の mrblib と同じ役目)。
# 回路は primitive (tools/fpga/isa.rb の PRIMS) とメソッド探索だけを持ち、それを組み合わせるメソッドはここに Ruby で書く。
# CRuby / picoruby でも同じ意味になる書き方だけを使う (参照の突き合わせで CRuby に同じ file を読ませる)。

class Integer
  def times
    i = 0
    while i < self
      yield i
      i += 1
    end
    self
  end

  def upto(last)
    i = self
    while i <= last
      yield i
      i += 1
    end
    self
  end

  def downto(last)
    i = self
    while i >= last
      yield i
      i -= 1
    end
    self
  end
end

class Array
  def each
    i = 0
    while i < size
      yield __aget(i)
      i += 1
    end
    self
  end

  def each_with_index
    i = 0
    while i < size
      yield __aget(i), i
      i += 1
    end
    self
  end

  def map
    result = []
    i = 0
    while i < size
      result << yield(__aget(i))
      i += 1
    end
    result
  end
end

class Object
  def loop
    while true
      yield
    end
  end

  def proc(&block)
    block
  end

  # 動的な呼び出し (P7)。回路の __send (名前の Symbol を外して残りの引数で呼ぶ) に引数の数で分けて渡す
  # (splat で渡すと引数が配列1つになり、primitive の受け手の検査が通らないため)。名前は Symbol か String
  # (String はプログラムのシンボル表から探し、無ければどのメソッドの名前でもないので NoMethodError)
  def send(name, *args, &blk)
    if name.is_a?(String)
      s = name.__find_sym
      raise NoMethodError, "undefined method '#{name}' for #{self.class}" unless s
      name = s
    end
    raise TypeError, "#{name.inspect} is not a symbol nor a string" unless name.is_a?(Symbol)
    case args.size
    when 0 then __send(name, &blk)
    when 1 then __send(name, args[0], &blk)
    when 2 then __send(name, args[0], args[1], &blk)
    when 3 then __send(name, args[0], args[1], args[2], &blk)
    when 4 then __send(name, args[0], args[1], args[2], args[3], &blk)
    when 5 then __send(name, args[0], args[1], args[2], args[3], args[4], &blk)
    when 6 then __send(name, args[0], args[1], args[2], args[3], args[4], args[5], &blk)
    else raise ArgumentError, "send passes up to 6 arguments on the FPGA core"
    end
  end

  # defined?(X) の値 (X がクラスかモジュールの時。変換器が __defined_const? をこれにする)
  def __const_str
    "constant"
  end

  # 即値だけ (ヒープのオブジェクトはコピー GC で動くので決まった数を持てない)
  def object_id
    id = __object_id
    raise NotImplementedError, "object_id of a heap object is not available on the FPGA core" if id.nil?
    id
  end

  def __send__(name, *args, &blk)
    send(name, *args, &blk)
  end

  def public_send(name, *args, &blk)
    send(name, *args, &blk)
  end
end

class Object
  def !=(other)
    !(self == other)
  end
end

class Array
  def ==(other)
    return false unless other.class == Array
    return false unless size == other.size
    i = 0
    while i < size
      return false unless __aget(i) == other.__aget(i)
      i += 1
    end
    true
  end

  def include?(value)
    each { |x| return true if x == value }
    false
  end
end

class Object
  def initialize
  end

  def nil?
    false
  end

  def instance_of?(klass)
    self.class == klass
  end
end

class NilClass
  def nil?
    true
  end
end

class Module
  def ===(object)
    object.is_a?(self)
  end
end

class Object
  # require は変換の前に解いてある (tools/fpga/corpus.rb の gem_files)。実行時は何もしない
  def require(name)
    true
  end

  # プログラムは1つの .rb にまとめて変換するので、別の file は読めない
  def require_relative(name)
    raise NotImplementedError, "require_relative '#{name}': the FPGA core runs one converted program (no files)"
  end

  # 板にプロセスは無い
  def `(command)
    raise NotImplementedError, "`#{command}`: the FPGA core has no processes"
  end

  # mruby の Kernel#caller (mrb_f_caller)。list は caller を呼んだメソッドのフレームから (docs/spec.md §10「picotest と caller」)。
  # mruby の backtrace は caller 自身の段を先頭に持つので、その長さは list より 1 つ多い
  def caller(start = 1, length = nil)
    list = __backtrace
    len = list.size + 1
    if start.is_a?(Range)
      raise TypeError, "no implicit conversion of Range into Integer" if length
      lev = start.begin || 0
      fin = start.end
      lev += len if lev < 0
      return nil if lev < 0 || lev > len
      fin = len if fin.nil?
      fin += len if fin < 0
      fin += 1 unless start.exclude_end?
      fin = len if fin > len
      n = fin - lev
      n = 0 if n < 0
    else
      raise TypeError, "no implicit conversion of #{start.class} into Integer" unless start.is_a?(Integer)
      lev = start
      n = length.nil? ? len - lev : length
    end
    return nil if lev >= len
    raise ArgumentError, "negative level (#{start})" if lev < 0
    raise ArgumentError, "negative size (#{n})" if n < 0
    return [] if n == 0
    n = len - lev - 1 if len <= n + lev
    list[lev, n]
  end

  # フレームごとの "<file>:<line>:in <method>"。pc を __frame_pc で集め、変換器の置いた表 ($__caller_table =
  # 先頭 << 16 | 区間の数、1区間2語 {pc, 行} {ファイル, メソッド}) を二分探索する。プレリュードと gem の区間 (0xFFFE) は数えない
  def __backtrace
    t = $__caller_table
    r = []
    return r unless t
    base = t >> 16
    n = t & 0xFFFF
    k = 0
    while (pc = __frame_pc(k))
      lo = 0
      hi = n - 1
      e = -1
      while lo <= hi
        m = (lo + hi) >> 1
        if ((base + 2 * m).__rom_word >> 16) <= pc
          e = m
          lo = m + 1
        else
          hi = m - 1
        end
      end
      if e >= 0
        w0 = (base + 2 * e).__rom_word
        w1 = (base + 2 * e + 1).__rom_word
        mid = w1 & 0xFFFF
        if mid != 0xFFFE
          s = "#{(w1 >> 16).__sym_at}:#{w0 & 0xFFFF}"
          s = "#{s}:in #{mid.__sym_at}" if mid != 0xFFFF
          r << s
        end
      end
      k += 1
    end
    r
  end

  # シンボル表を順に見て、受け手が応えるものを返す (mruby はメソッド表の順。こちらはシンボル表の順)
  def methods
    r = []
    i = 0
    while (s = i.__sym_at)
      r << s if respond_to?(s)
      i += 1
    end
    r
  end
end

class Module
  # 引数がシンボルのリテラルなら、変換器がクラスの本体の alias と同じく静的に解く (メソッド表は ROM)。ここに来るのはそれ以外
  def alias_method(new_name, old_name)
    raise NotImplementedError, "alias_method with non-literal names: the method table of the FPGA core is in ROM"
  end
end

# mruby の定数 (PicoRuby の host の VM と同じ値。tools/fpga/ref_vm_test.rb が vendor/picoruby の version.h と比べる)。
# RUBY_PLATFORM はこのコアの名前
RUBY_ENGINE = "mruby"
RUBY_VERSION = "4.0"
MRUBY_VERSION = "4.0.0"
PICORUBY_VERSION = "4.0.4"
RUBY_PLATFORM = "fpga-mrb_core"

# GC はヒープが足りなくなった時にコアが動かす (コピー GC)。start は何もしない (いつ動いても結果は同じ)
module GC
  def self.start
    nil
  end
end

class Proc
  # Proc.new { } はブロックの Proc そのもの
  def self.new(&block)
    raise ArgumentError, "tried to create Proc object without a block" unless block
    block
  end
end
