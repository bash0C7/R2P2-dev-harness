# caller (P9)。"<file>:<line>:in <method>" の並び (プログラムの .rb のフレームだけ。プレリュードの each などは数えない)、
# 引数 (位置、位置と数、Range)、ブロック、main。host の picoruby と全行一致を見る (tools/fpga/ref_vm_test.rb)
def base(s)
  s.nil? ? nil : s.map { |l| l.split("/").last }
end

class Walker
  def inner
    caller(0)
  end

  def middle
    inner
  end

  def outer
    middle
  end

  def in_block
    r = nil
    [1].each { r = caller(0, 2) }
    r
  end

  def via_yield
    yield
  end

  def levels
    [caller.size, caller(1).size, caller(0, 1), caller(1, 1), caller(100), caller(0, 0), caller(0..1), caller(1...2), caller(-2..-1)]
  end
end

w = Walker.new
p base(w.outer)
p base(w.in_block)
p base(w.via_yield { caller(0) })
lv = w.levels
p lv[0], lv[1]
p base(lv[2]), base(lv[3]), lv[4], lv[5], base(lv[6]), base(lv[7]), base(lv[8])
p base(caller(0))
begin
  caller(-1)
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end
begin
  caller(0, -1)
rescue ArgumentError => e
  puts "#{e.class}: #{e.message}"
end
$LED = w.outer.size
