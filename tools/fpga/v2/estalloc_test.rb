require "minitest/autorun"
require "fiddle"
require "tmpdir"
require "open3"
require_relative "est_host"
require_relative "build"

# 計画 S6-1: firmware の estalloc (fpga/firmware/estalloc.rb、32bit の形) を、picoruby-machine の estalloc.c を 64bit で build した .so と比べる。
# 戻りの番地は BPOOL_TOP からの差で比べる (32bit と 64bit で違うのは FREE_BLOCK の大きさ、top_adrs の位置、POOL_HEADER_SIZE だけ、D25)
class FpgaV2EstallocTest < Minitest::Test
  L = FpgaV2::Layout
  EST_DIR = File.join(FpgaV2::Build::ROOT, "vendor", "picoruby", "mrbgems", "picoruby-machine", "lib", "estalloc")
  P = Fiddle::TYPE_VOIDP
  U = Fiddle::TYPE_UINT

  # C の estalloc (64bit、組み込みの build と同じ ESTALLOC_ALIGNMENT 8、DEBUG 無し)
  class CEst
    def self.lib
      @lib ||= begin
        dir = Dir.mktmpdir("estalloc")
        so = File.join(dir, "libestalloc.so")
        out, st = Open3.capture2e("cc", "-shared", "-fPIC", "-O0", "-DESTALLOC_ALIGNMENT=8", "-o", so, File.join(EST_DIR, "estalloc.c"))
        raise "cc estalloc.c failed:\n#{out}" unless st.success?

        Fiddle.dlopen(so)
      end
    end

    def self.fn(name, args, ret) = Fiddle::Function.new(lib[name], args, ret)

    def initialize(size)
      @buf = Fiddle::Pointer.malloc(size + 16, Fiddle::RUBY_FREE)
      base = (@buf.to_i + 7) & -8
      @size = size
      init = self.class.fn("est_init", [P, U], P)
      # BPOOL_TOP の位置 (POOL_HEADER_SIZE): 初めの確保は BPOOL_TOP の 1 つだけのブロックから取る
      @pool = init.call(base, size).to_i
      @header = self.class.fn("est_malloc", [P, U], P).call(@pool, 1).to_i - 8 - @pool
      init.call(base, size)
      @malloc = self.class.fn("est_malloc", [P, U], P)
      @calloc = self.class.fn("est_calloc", [P, U, U], P)
      @realloc = self.class.fn("est_realloc", [P, P, U], P)
      @permalloc = self.class.fn("est_permalloc", [P, U], P)
      @free = self.class.fn("est_free", [P, P], Fiddle::TYPE_VOID)
      @usable = self.class.fn("est_usable_size", [P, P], U)
      @stat = self.class.fn("est_take_statistics", [P], Fiddle::TYPE_VOID)
    end

    attr_reader :header

    def top = @pool + @header
    def off(p) = p.to_i.zero? ? nil : p.to_i - top
    def ptr(o) = o + top
    def malloc(n) = off(@malloc.call(@pool, n))
    def calloc(m, n) = off(@calloc.call(@pool, m, n))
    def realloc(o, n) = off(@realloc.call(@pool, o ? ptr(o) : 0, n))
    def permalloc(n) = off(@permalloc.call(@pool, n))
    def free(o) = @free.call(@pool, ptr(o))
    def usable(o) = @usable.call(@pool, ptr(o))
    def poke(o, bytes) = Fiddle::Pointer.new(ptr(o))[0, bytes.bytesize] = bytes
    def peek(o, n) = Fiddle::Pointer.new(ptr(o))[0, n]

    # ESTALLOC_STAT (total、used、free、max_free、frag)。total は見出しを除いて比べる
    def stat
      @stat.call(@pool)
      t, u, f, m, g = Fiddle::Pointer.new(@pool)[0, 20].unpack("L5")
      [t - @header, u, f, m, g]
    end
  end

  # firmware の estalloc (est_host で CRuby の上で)。pool は C と使える領域の大きさをそろえる
  class FwEst
    def initialize(usable_size)
      @base = 64
      @mem = "\0".b * (@base + usable_size + L::POOL_HEADER_SIZE + 64)
      @h = FpgaV2::EstHost.new(@mem)
      @h.call(:__fpga_est_init, @base, usable_size + L::POOL_HEADER_SIZE)
    end

    def top = @base + L::POOL_HEADER_SIZE
    def off(p) = p.zero? ? nil : p - top
    def c(name, *a) = @h.call(name, @base, *a)
    def malloc(n) = off(c(:__fpga_est_malloc, n))
    def calloc(m, n) = off(c(:__fpga_est_calloc, m, n))
    def realloc(o, n) = off(c(:__fpga_est_realloc, o ? o + top : 0, n))
    def permalloc(n) = off(c(:__fpga_est_permalloc, n))
    def free(o) = c(:__fpga_est_free, o + top)
    def usable(o) = c(:__fpga_est_usable_size, o + top)
    def poke(o, bytes) = @mem[o + top, bytes.bytesize] = bytes
    def peek(o, n) = @mem.byteslice(o + top, n)

    def stat
      c(:__fpga_est_take_statistics)
      t, u, f, m, g = @mem.byteslice(@base, 20).unpack("N5")
      [t - L::POOL_HEADER_SIZE, u, f, m, g]
    end
  end

  # 戻りの比べ (NULL は nil)
  def same(a, b, msg)
    a.nil? ? assert_nil(b, msg) : assert_equal(a, b, msg)
  end

  def size_of(rng)
    r = rng.rand(100)
    return rng.rand(0..300) if r < 80
    return rng.rand(1..4000) if r < 95

    rng.rand(1..70_000)
  end

  # 同じ操作の列を C と firmware に与え、戻りと usable_size と統計を比べる
  def run_seq(seed, pool_size, steps)
    c = CEst.new(pool_size)
    f = FwEst.new(pool_size - c.header)
    rng = Random.new(seed)
    live = [] # [off, 書いた bytes]
    tag = 0
    nulls = 0
    steps.times do |step|
      where = "seed #{seed} step #{step}"
      op = rng.rand(100)
      if op < 45 || live.empty?
        n = size_of(rng)
        a = c.malloc(n)
        b = f.malloc(n)
        same a, b, "#{where}: malloc(#{n})"
      elsif op < 52
        m = rng.rand(0..20)
        n = rng.rand(0..40)
        a = c.calloc(m, n)
        b = f.calloc(m, n)
        same a, b, "#{where}: calloc(#{m}, #{n})"
        assert_equal c.peek(a, m * n), f.peek(b, m * n), "#{where}: calloc clears" if a
      elsif op < 72
        o, = live.delete_at(rng.rand(live.size))
        c.free(o)
        f.free(o)
        next
      elsif op < 97
        i = rng.rand(live.size)
        o, bytes = live[i]
        n = size_of(rng)
        a = c.realloc(o, n)
        b = f.realloc(o, n)
        same a, b, "#{where}: realloc(#{o}, #{n})"
        if a
          k = [bytes.bytesize, n].min
          assert_equal bytes.byteslice(0, k), c.peek(a, k), "#{where}: C keeps the bytes"
          assert_equal bytes.byteslice(0, k), f.peek(b, k), "#{where}: firmware keeps the bytes"
          live.delete_at(i)
        else
          next
        end
      else
        n = rng.rand(0..200)
        same c.permalloc(n), f.permalloc(n), "#{where}: permalloc(#{n})"
        next # permalloc の物は free しない
      end
      nulls += 1 unless a
      next unless a

      assert_equal c.usable(a), f.usable(b), "#{where}: usable_size"
      tag += 1
      bytes = [tag].pack("N") * 2
      bytes = bytes.byteslice(0, [c.usable(a), 8].min)
      c.poke(a, bytes)
      f.poke(b, bytes)
      live << [a, bytes]
      assert_equal c.stat, f.stat, "#{where}: statistics" if (step % 25).zero?
    end
    assert_equal c.stat, f.stat, "seed #{seed}: statistics at the end"
    nulls
  end

  def test_same_as_c_on_a_large_pool
    (1..10).each { |seed| run_seq(seed, 1 << 20, 2000) }
  end

  # 小さい pool: 尽きて NULL を返す所まで
  def test_same_as_c_until_exhausted
    nulls = (11..20).sum { |seed| run_seq(seed, 32 * 1024, 2000) }
    assert_operator nulls, :>, 0, "the small pool runs out"
  end

  # 見出しの形: 32bit の MEMORY_POOL は 376 バイト、使える領域の頭は BPOOL_TOP
  def test_pool_header_layout
    f = FwEst.new(4096)
    assert_equal 8, f.malloc(1) # BPOOL_TOP + sizeof(USED_BLOCK)
    assert_equal 8 + 32, f.malloc(1) # 最小のブロック (ESTALLOC_MIN_MEMORY_BLOCK_SIZE) の次
  end

  # 計画 S6-1: ref の上の firmware も、CRuby の上の同じ firmware (est_host) と同じ番地を返す (C、CRuby、ref の 3 者)
  def test_firmware_on_ref_matches_est_host
    rng = Random.new(99)
    pool = 24 * 1024 * 1024
    size = 16 * 1024
    ops = []
    live = []
    200.times do
      if live.empty? || rng.rand(100) < 50
        ops << [:malloc, rng.rand(0..600)]
        live << ops.size - 1
      elsif rng.rand(100) < 50
        ops << [:free, live.delete_at(rng.rand(live.size))]
      else
        i = rng.rand(live.size)
        ops << [:realloc, live[i], rng.rand(0..900)]
        live[i] = ops.size - 1
      end
    end
    src = +"pool = #{pool}\n__fpga_est_init(pool, #{size})\nr = []\n"
    ops.each_with_index do |(op, x, y), i|
      src << case op
             when :malloc then "r[#{i}] = __fpga_est_malloc(pool, #{x})\n"
             when :free then "__fpga_est_free(pool, r[#{x}])\nr[#{i}] = 0\n"
             else "r[#{i}] = __fpga_est_realloc(pool, r[#{x}], #{y})\n"
             end
      src << "puts r[#{i}] == 0 ? 0 : r[#{i}] - pool\n"
    end
    src << "__fpga_est_take_statistics(pool)\ni = 0\nwhile i < 5\n  puts __fpga_ld32(pool + i * 4)\n  i += 1\nend\n"
    out, = FpgaV2::Build.run_source(src, max_steps: 50_000_000)

    mem = "\0".b * (size + 64)
    h = FpgaV2::EstHost.new(mem)
    base = 0
    h.call(:__fpga_est_init, base, size)
    r = []
    want = +""
    ops.each_with_index do |(op, x, y), i|
      r[i] = case op
             when :malloc then h.call(:__fpga_est_malloc, base, x)
             when :free then (h.call(:__fpga_est_free, base, r[x]); 0)
             else h.call(:__fpga_est_realloc, base, r[x], y)
             end
      want << "#{r[i].zero? ? 0 : r[i] - base}\n"
    end
    h.call(:__fpga_est_take_statistics, base)
    5.times { |k| want << "#{mem.byteslice(base + k * 4, 4).unpack1('N')}\n" }
    assert_equal want, out
  end
end
