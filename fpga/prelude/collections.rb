# Hash、Range、Enumerable、Array の残り、Comparable、Integer の残り。
# Hash と Range は Ruby のクラス (組み込みの番号のまま、インスタンス変数を持つ)。作る命令 (HASH / RANGE_INC ...) は
# 変換器がここのメソッドの呼び出しにする (__to_hash / __add_pairs / __merge! / __range_inc / __range_exc)。

module Comparable
  def <(other)
    (self <=> other) < 0
  end

  def <=(other)
    (self <=> other) <= 0
  end

  def >(other)
    (self <=> other) > 0
  end

  def >=(other)
    (self <=> other) >= 0
  end

  def ==(other)
    r = (self <=> other)
    !r.nil? && r == 0
  end

  def between?(min, max)
    self >= min && self <= max
  end

  def clamp(min, max)
    return min if self < min
    return max if self > max
    self
  end
end

# each を持つクラス (Array、Hash、Range) が共有する。Hash の each は [key, value] を1つ yield する
module Enumerable
  def to_a
    r = []
    each { |x| r << x }
    r
  end

  def entries
    to_a
  end

  def map
    r = []
    each { |x| r << yield(x) }
    r
  end

  def collect
    r = []
    each { |x| r << yield(x) }
    r
  end

  def flat_map
    r = []
    each do |x|
      y = yield(x)
      y.is_a?(Array) ? y.each { |z| r << z } : r << y
    end
    r
  end

  def select
    r = []
    each { |x| r << x if yield(x) }
    r
  end

  def filter
    r = []
    each { |x| r << x if yield(x) }
    r
  end

  def reject
    r = []
    each { |x| r << x unless yield(x) }
    r
  end

  def filter_map
    r = []
    each do |x|
      y = yield(x)
      r << y if y
    end
    r
  end

  def partition
    a = []
    b = []
    each { |x| yield(x) ? a << x : b << x }
    [a, b]
  end

  def find
    each { |x| return x if yield(x) }
    nil
  end

  def detect
    each { |x| return x if yield(x) }
    nil
  end

  def find_index(value = nil)
    i = 0
    each do |x|
      return i if (block_given? ? yield(x) : x == value)
      i += 1
    end
    nil
  end

  def include?(value)
    each { |x| return true if x == value }
    false
  end

  def member?(value)
    include?(value)
  end

  def count(value = nil)
    n = 0
    if block_given?
      each { |x| n += 1 if yield(x) }
    elsif value.nil?
      each { |x| n += 1 }
    else
      each { |x| n += 1 if x == value }
    end
    n
  end

  def inject(init = nil, sym = nil)
    acc = init
    first = init.nil?
    if init.is_a?(Symbol) && sym.nil?
      sym = init
      acc = nil
      first = true
    end
    each do |x|
      if first
        acc = x
        first = false
      elsif sym
        acc = acc.__send_op(sym, x)
      else
        acc = yield(acc, x)
      end
    end
    acc
  end

  def reduce(init = nil, sym = nil, &blk)
    inject(init, sym, &blk)
  end

  def sum(init = 0)
    acc = init
    if block_given?
      each { |x| acc += yield(x) }
    else
      each { |x| acc += x }
    end
    acc
  end

  def min(&blk)
    r = nil
    each { |x| r = x if r.nil? || (blk ? blk.call(x, r) < 0 : x < r) }
    r
  end

  def max(&blk)
    r = nil
    each { |x| r = x if r.nil? || (blk ? blk.call(x, r) > 0 : x > r) }
    r
  end

  def min_by
    r = nil
    rv = nil
    each do |x|
      v = yield(x)
      if rv.nil? || v < rv
        r = x
        rv = v
      end
    end
    r
  end

  def max_by
    r = nil
    rv = nil
    each do |x|
      v = yield(x)
      if rv.nil? || v > rv
        r = x
        rv = v
      end
    end
    r
  end

  def minmax
    [min, max]
  end

  def sort(&blk)
    to_a.sort(&blk)
  end

  def sort_by(&blk)
    to_a.sort_by(&blk)
  end

  def each_with_index
    i = 0
    each do |x|
      yield x, i
      i += 1
    end
    self
  end

  def each_with_object(memo)
    each { |x| yield x, memo }
    memo
  end

  def each_slice(n)
    buf = []
    each do |x|
      buf << x
      if buf.size == n
        yield buf
        buf = []
      end
    end
    yield buf unless buf.empty?
    self
  end

  def each_cons(n)
    buf = []
    each do |x|
      buf << x
      buf.shift if buf.size > n
      yield buf.dup if buf.size == n
    end
    self
  end

  def first(n = nil)
    if n.nil?
      each { |x| return x }
      return nil
    end
    r = []
    return r if n <= 0
    each do |x|
      r << x
      return r if r.size >= n
    end
    r
  end

  def take(n)
    first(n)
  end

  def take_while
    r = []
    each do |x|
      return r unless yield(x)
      r << x
    end
    r
  end

  def drop(n)
    r = []
    i = 0
    each do |x|
      r << x if i >= n
      i += 1
    end
    r
  end

  def drop_while
    r = []
    dropping = true
    each do |x|
      dropping = false if dropping && !yield(x)
      r << x unless dropping
    end
    r
  end

  def group_by
    h = {}
    each do |x|
      k = yield(x)
      h[k] = [] unless h.key?(k)
      h[k] << x
    end
    h
  end

  def tally
    h = {}
    each { |x| h[x] = (h[x] || 0) + 1 }
    h
  end

  def uniq
    r = []
    each { |x| r << x unless r.include?(x) }
    r
  end

  def zip(*others)
    r = []
    i = 0
    each do |x|
      row = [x]
      others.each { |o| row << o.to_a[i] }
      r << row
      i += 1
    end
    r
  end

  def any?(value = nil)
    each { |x| return true if (block_given? ? yield(x) : (value.nil? ? x : value === x)) }
    false
  end

  def all?(value = nil)
    each { |x| return false unless (block_given? ? yield(x) : (value.nil? ? x : value === x)) }
    true
  end

  def none?(value = nil)
    each { |x| return false if (block_given? ? yield(x) : (value.nil? ? x : value === x)) }
    true
  end

  def one?
    n = 0
    each { |x| n += 1 if (block_given? ? yield(x) : x) }
    n == 1
  end

  def reverse_each
    to_a.reverse.each { |x| yield x }
    self
  end

  def to_h
    h = {}
    each do |x|
      pair = block_given? ? yield(x) : x
      h[pair[0]] = pair[1]
    end
    h
  end
end

class Object
  # Hash のキーの比較。既定は同じものか (Integer、String、Array は値で比べる)
  def eql?(other)
    equal?(other)
  end

  def hash
    0
  end

  # inject(:+) など: 演算子のシンボルでメソッドを送る (send が無いので名前で分ける)
  def __send_op(sym, x)
    if sym == :+ then self + x
    elsif sym == :- then self - x
    elsif sym == :* then self * x
    elsif sym == :/ then self / x
    elsif sym == :% then self % x
    elsif sym == :& then self & x
    elsif sym == :| then self | x
    elsif sym == :^ then self ^ x
    elsif sym == :<< then self << x
    elsif sym == :max then (self > x ? self : x)
    elsif sym == :min then (self < x ? self : x)
    else __send_with_this_symbol_is_not_supported(sym)
    end
  end

  def __range_inc(last)
    Range.new(self, last, false)
  end

  def __range_exc(last)
    Range.new(self, last, true)
  end

  def Integer(x)
    x.is_a?(String) ? x.to_i : x.to_i
  end

  def Array(x)
    return [] if x.nil?
    x.is_a?(Array) ? x : (x.respond_to?(:to_a) ? x.to_a : [x])
  end
end

class Integer
  include Comparable

  def <=>(other)
    return nil unless other.is_a?(Integer)
    self < other ? -1 : (self > other ? 1 : 0)
  end

  def succ
    self + 1
  end

  def next
    self + 1
  end

  def pred
    self - 1
  end

  def **(n)
    r = 1
    b = self
    while n > 0
      r *= b if n.odd?
      b *= b
      n >>= 1
    end
    r
  end

  def pow(n)
    self**n
  end

  def divmod(n)
    [self / n, self % n]
  end

  def remainder(n)
    r = self % n
    r != 0 && (self < 0) != (n < 0) ? r - n : r
  end

  def gcd(n)
    a = abs
    b = n.abs
    while b != 0
      t = a % b
      a = b
      b = t
    end
    a
  end

  def lcm(n)
    return 0 if self == 0 || n == 0
    (self * n).abs / gcd(n)
  end

  def positive?
    self > 0
  end

  def negative?
    self < 0
  end

  def nonzero?
    self == 0 ? nil : self
  end

  def integer?
    true
  end

  def digits(base = 10)
    return [0] if self == 0
    r = []
    n = self
    while n > 0
      r << n % base
      n /= base
    end
    r
  end

  def bit_length
    n = self < 0 ? ~self : self
    b = 0
    while n > 0
      b += 1
      n >>= 1
    end
    b
  end

  def [](i)
    (self >> i) & 1
  end

  def step(limit, by = 1)
    i = self
    if by > 0
      while i <= limit
        yield i
        i += by
      end
    else
      while i >= limit
        yield i
        i += by
      end
    end
    self
  end

  def hash
    self
  end

  def eql?(other)
    other.is_a?(Integer) && self == other
  end
end

class Range
  include Enumerable

  def initialize(first, last, exclude_end = false)
    @first = first
    @last = last
    @excl = exclude_end
  end

  def first(n = nil)
    return @first if n.nil?
    super(n)
  end

  def begin
    @first
  end

  def last(n = nil)
    return @last if n.nil?
    to_a.last(n)
  end

  def end
    @last
  end

  def exclude_end?
    @excl
  end

  # Integer の範囲だけ (String の範囲は止める)
  def each
    __non_integer_ranges_are_not_supported unless @first.is_a?(Integer)
    i = @first
    if @last.nil?
      while true
        yield i
        i += 1
      end
    end
    last = @excl ? @last - 1 : @last
    while i <= last
      yield i
      i += 1
    end
    self
  end

  def reverse_each
    i = @excl ? @last - 1 : @last
    while i >= @first
      yield i
      i -= 1
    end
    self
  end

  def size
    return nil unless @first.is_a?(Integer)
    n = (@excl ? @last - 1 : @last) - @first + 1
    n < 0 ? 0 : n
  end

  def count(value = nil, &blk)
    return size if value.nil? && blk.nil?
    super(value, &blk)
  end

  # CRuby の cover? と同じく <=> で比べ、比べられなければ false
  def include?(x)
    c = (@first <=> x)
    return false if c.nil? || c > 0
    return true if @last.nil?
    c = (x <=> @last)
    return false if c.nil?
    @excl ? c < 0 : c <= 0
  end

  def member?(x)
    include?(x)
  end

  def cover?(x)
    include?(x)
  end

  def ===(x)
    include?(x)
  end

  def min
    @first
  end

  def max
    @excl ? @last - 1 : @last
  end

  def sum(init = 0, &blk)
    return super(init, &blk) if blk || !@first.is_a?(Integer)
    n = size
    init + (@first + max) * n / 2
  end

  def step(n)
    i = @first
    last = @excl ? @last - 1 : @last
    while i <= last
      yield i
      i += n
    end
    self
  end

  def to_s
    @first.to_s + (@excl ? "..." : "..") + @last.to_s
  end

  def inspect
    @first.inspect + (@excl ? "..." : "..") + @last.inspect
  end

  def ==(other)
    other.is_a?(Range) && @first == other.begin && @last == other.end && @excl == other.exclude_end?
  end

  def dup
    Range.new(@first, @last, @excl)
  end
end

class Hash
  include Enumerable

  def initialize(default = nil, &block)
    @keys = []
    @vals = []
    @default = default
    @default_proc = block
  end

  def __index(key)
    i = 0
    n = @keys.size
    while i < n
      return i if @keys.__aget(i).eql?(key)
      i += 1
    end
    nil
  end

  def [](key)
    i = __index(key)
    return @vals.__aget(i) if i
    return @default_proc.call(self, key) if @default_proc
    @default
  end

  def []=(key, value)
    i = __index(key)
    if i
      @vals[i] = value
    else
      @keys << key
      @vals << value
    end
    value
  end

  def store(key, value)
    self[key] = value
  end

  def fetch(key, *default)
    i = __index(key)
    return @vals.__aget(i) if i
    return yield(key) if block_given?
    return default[0] unless default.empty?
    __key_not_found(key)
  end

  def key?(key)
    !__index(key).nil?
  end

  def has_key?(key)
    key?(key)
  end

  def include?(key)
    key?(key)
  end

  def member?(key)
    key?(key)
  end

  def value?(value)
    @vals.include?(value)
  end

  def has_value?(value)
    value?(value)
  end

  def key(value)
    i = @vals.index(value)
    i && @keys.__aget(i)
  end

  def delete(key)
    i = __index(key)
    return (block_given? ? yield(key) : nil) unless i
    v = @vals.__aget(i)
    @keys.delete_at(i)
    @vals.delete_at(i)
    v
  end

  def keys
    @keys.dup
  end

  def values
    @vals.dup
  end

  def values_at(*ks)
    ks.map { |k| self[k] }
  end

  def size
    @keys.size
  end

  def length
    @keys.size
  end

  def count(value = nil, &blk)
    return size if value.nil? && blk.nil?
    super(value, &blk)
  end

  def empty?
    @keys.empty?
  end

  def each
    i = 0
    while i < @keys.size
      yield [@keys.__aget(i), @vals.__aget(i)]
      i += 1
    end
    self
  end

  def each_pair(&blk)
    each(&blk)
  end

  def each_key
    @keys.dup.each { |k| yield k }
    self
  end

  def each_value
    @vals.dup.each { |v| yield v }
    self
  end

  def to_h
    self
  end

  def to_a
    r = []
    each { |pair| r << pair }
    r
  end

  def dup
    h = Hash.new(@default)
    each { |k, v| h[k] = v }
    h
  end

  def merge(other = nil)
    h = dup
    other.each { |k, v| h[k] = (block_given? && h.key?(k) ? yield(k, h[k], v) : v) } if other
    h
  end

  def merge!(other)
    other.each { |k, v| self[k] = (block_given? && key?(k) ? yield(k, self[k], v) : v) }
    self
  end

  def update(other)
    merge!(other)
  end

  def select
    h = {}
    each { |k, v| h[k] = v if yield(k, v) }
    h
  end

  def filter
    h = {}
    each { |k, v| h[k] = v if yield(k, v) }
    h
  end

  def reject
    h = {}
    each { |k, v| h[k] = v unless yield(k, v) }
    h
  end

  def delete_if
    each { |k, v| delete(k) if yield(k, v) }
    self
  end

  def keep_if
    each { |k, v| delete(k) unless yield(k, v) }
    self
  end

  def transform_values
    h = {}
    each { |k, v| h[k] = yield(v) }
    h
  end

  def transform_keys
    h = {}
    each { |k, v| h[yield(k)] = v }
    h
  end

  def invert
    h = {}
    each { |k, v| h[v] = k }
    h
  end

  def compact
    h = {}
    each { |k, v| h[k] = v unless v.nil? }
    h
  end

  def clear
    @keys = []
    @vals = []
    self
  end

  def default
    @default
  end

  def default=(value)
    @default = value
  end

  def dig(key, *rest)
    v = self[key]
    rest.empty? || v.nil? ? v : v.dig(*rest)
  end

  def ==(other)
    return false unless other.is_a?(Hash) && other.size == size
    each { |k, v| return false unless other.key?(k) && other[k] == v }
    true
  end

  # PicoRuby (と CRuby 3.4) の形: {"a" => 1, b: 2}。Symbol のキーはいつも "名前: "
  def inspect
    r = "{"
    i = 0
    while i < @keys.size
      r << ", " if i > 0
      k = @keys.__aget(i)
      if k.is_a?(Symbol)
        r << k.to_s
        r << ": "
      else
        r << k.inspect
        r << " => "
      end
      r << @vals.__aget(i).inspect
      i += 1
    end
    r << "}"
  end

  def to_s
    inspect
  end

  def __add_pairs(pairs)
    i = 0
    while i < pairs.size
      self[pairs.__aget(i)] = pairs.__aget(i + 1)
      i += 2
    end
    self
  end

  def __merge!(other)
    merge!(other)
  end

  # キーワード引数 (KARG / KEYEND を変換器がこの呼び出しにする)。KARG は Hash から消す (**opts には残りが入る)
  def __karg(key)
    return delete(key) if key?(key)
    __missing_keyword(key)
  end

  def __keyend
    __unknown_keyword(@keys.__aget(0)) unless empty?
  end
end

class Array
  include Enumerable

  def self.new(n = 0, value = nil)
    r = []
    i = 0
    while i < n
      r << (block_given? ? yield(i) : value)
      i += 1
    end
    r
  end

  # {k => v, ...} のリテラル (HASH): [k0, v0, k1, v1, ...] から
  def __to_hash
    Hash.new.__add_pairs(self)
  end

  # a[i]、a[i, n]、a[range]。a[i] (i が整数) は GETIDX がその場で読むので、ここに来るのは主に self[i] と切り出し
  def [](i, n = nil)
    if n.nil?
      return __aget(i) if i.is_a?(Integer)
      __not_an_index(i) unless i.is_a?(Range)
      len = size
      s = i.begin
      s += len if s < 0
      e = i.end.nil? ? len - 1 : i.end
      e += len if e < 0
      e -= 1 if i.exclude_end?
      return nil if s < 0 || s > len
      n = e - s + 1
      n = 0 if n < 0
      i = s
    end
    len = size
    i += len if i < 0
    return nil if i < 0 || i > len || n < 0
    n = len - i if i + n > len
    r = []
    k = 0
    while k < n
      r << __aget(i + k)
      k += 1
    end
    r
  end

  def slice(i, n = nil)
    self[i, n]
  end

  def at(i)
    __aget(i)
  end

  def dig(i, *rest)
    v = __aget(i)
    rest.empty? || v.nil? ? v : v.dig(*rest)
  end

  def push(*xs)
    xs.each { |x| self << x }
    self
  end

  def append(*xs)
    push(*xs)
  end

  def first(n = nil)
    return __aget(0) if n.nil?
    self[0, n]
  end

  def last(n = nil)
    return __aget(size - 1) if n.nil?
    n = size if n > size
    self[size - n, n]
  end

  def to_a
    self
  end

  def entries
    dup
  end

  def dup
    self[0, size]
  end

  def clone
    dup
  end

  def concat(*others)
    others.each { |o| o.each { |x| self << x } }
    self
  end

  def +(other)
    dup.concat(other)
  end

  def -(other)
    reject { |x| other.include?(x) }
  end

  def *(n)
    return join(n) if n.is_a?(String)
    r = []
    n.times { concat_to(r) }
    r
  end

  def concat_to(r)
    each { |x| r << x }
  end

  def &(other)
    r = []
    each { |x| r << x if other.include?(x) && !r.include?(x) }
    r
  end

  def |(other)
    r = uniq
    other.each { |x| r << x unless r.include?(x) }
    r
  end

  def <=>(other)
    i = 0
    while i < size && i < other.size
      c = __aget(i) <=> other.__aget(i)
      return c unless c == 0
      i += 1
    end
    size <=> other.size
  end

  def eql?(other)
    self == other
  end

  def hash
    h = size
    each { |x| h = (h * 31 + x.hash) & 0x3FFFFFFF }
    h
  end

  def index(value = nil)
    i = 0
    while i < size
      return i if (block_given? ? yield(__aget(i)) : __aget(i) == value)
      i += 1
    end
    nil
  end

  def find_index(value = nil, &blk)
    index(value, &blk)
  end

  def rindex(value = nil)
    i = size - 1
    while i >= 0
      return i if (block_given? ? yield(__aget(i)) : __aget(i) == value)
      i -= 1
    end
    nil
  end

  def reverse
    r = []
    i = size - 1
    while i >= 0
      r << __aget(i)
      i -= 1
    end
    r
  end

  def replace(other)
    clear
    other.each { |x| self << x }
    self
  end

  def reverse!
    replace(reverse)
  end

  def rotate(n = 1)
    return [] if empty?
    n %= size
    self[n, size - n] + self[0, n]
  end

  def clear
    pop until empty?
    self
  end

  def compact
    reject { |x| x.nil? }
  end

  def compact!
    replace(compact)
  end

  def delete(value)
    found = nil
    r = []
    each do |x|
      if x == value
        found = x
      else
        r << x
      end
    end
    replace(r)
    found
  end

  def delete_at(i)
    i += size if i < 0
    return nil if i < 0 || i >= size
    v = __aget(i)
    while i < size - 1
      self[i] = __aget(i + 1)
      i += 1
    end
    pop
    v
  end

  def delete_if
    replace(reject { |x| yield(x) })
  end

  def reject!
    n = size
    replace(reject { |x| yield(x) })
    size == n ? nil : self
  end

  def select!
    n = size
    replace(select { |x| yield(x) })
    size == n ? nil : self
  end

  def keep_if
    replace(select { |x| yield(x) })
  end

  def map!
    i = 0
    while i < size
      self[i] = yield(__aget(i))
      i += 1
    end
    self
  end

  def insert(i, *xs)
    i += size + 1 if i < 0
    rest = self[i, size - i]
    pop while size > i
    xs.each { |x| self << x }
    rest.each { |x| self << x }
    self
  end

  def unshift(*xs)
    insert(0, *xs)
  end

  def prepend(*xs)
    insert(0, *xs)
  end

  def shift(n = nil)
    return delete_at(0) if n.nil?
    r = self[0, n]
    r.size.times { delete_at(0) }
    r
  end

  def fill(value)
    i = 0
    while i < size
      self[i] = value
      i += 1
    end
    self
  end

  def values_at(*is)
    is.map { |i| __aget(i) }
  end

  def uniq!
    n = size
    replace(uniq)
    size == n ? nil : self
  end

  def flatten(depth = -1)
    r = []
    each do |x|
      if x.is_a?(Array) && depth != 0
        x.flatten(depth - 1).each { |y| r << y }
      else
        r << x
      end
    end
    r
  end

  def flatten!
    replace(flatten)
  end

  def transpose
    return [] if empty?
    r = []
    __aget(0).size.times { |j| r << map { |row| row[j] } }
    r
  end

  def sum(init = 0)
    acc = init
    i = 0
    while i < size
      acc += block_given? ? yield(__aget(i)) : __aget(i)
      i += 1
    end
    acc
  end

  # merge sort (安定)。blk があれば blk.call(a, b) < 0 で並べる
  def sort(&blk)
    return dup if size <= 1
    mid = size / 2
    a = self[0, mid].sort(&blk)
    b = self[mid, size - mid].sort(&blk)
    r = []
    i = 0
    j = 0
    while i < a.size && j < b.size
      x = a.__aget(i)
      y = b.__aget(j)
      if (blk ? blk.call(y, x) : (y <=> x)) < 0
        r << y
        j += 1
      else
        r << x
        i += 1
      end
    end
    while i < a.size
      r << a.__aget(i)
      i += 1
    end
    while j < b.size
      r << b.__aget(j)
      j += 1
    end
    r
  end

  def sort!(&blk)
    replace(sort(&blk))
  end

  def sort_by
    keyed = map { |x| [yield(x), x] }
    keyed.sort { |p, q| p[0] <=> q[0] }.map { |pair| pair[1] }
  end

  def sort_by!(&blk)
    replace(sort_by(&blk))
  end

  def min(&blk)
    return nil if empty?
    r = __aget(0)
    each { |x| r = x if (blk ? blk.call(x, r) < 0 : x < r) }
    r
  end

  def max(&blk)
    return nil if empty?
    r = __aget(0)
    each { |x| r = x if (blk ? blk.call(x, r) > 0 : x > r) }
    r
  end

  def take(n)
    self[0, n]
  end

  def drop(n)
    self[n, size - n] || []
  end

  def cycle
    return nil if empty?
    while true
      each { |x| yield x }
    end
  end

  def assoc(key)
    each { |pair| return pair if pair.is_a?(Array) && pair[0] == key }
    nil
  end

  def pack(*)
    __pack_is_not_supported
  end

  def freeze
    self
  end

  def frozen?
    false
  end
end
