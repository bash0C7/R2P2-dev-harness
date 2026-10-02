# 大域変数と splat (計画 S2c): GETGV / SETGV、ARYCAT / ARYPUSH をその場で、to_a を送る splat (mrb_ary_splat)、LOADL
$g = 3
puts $g
puts $nothing.nil?
$g += 4
puts $g

def count(*a)
  a.size
end

x = nil
puts count(*x)

class Pair
  def to_a
    [1, 2]
  end
end
puts count(*Pair.new)
puts count(*5)

a = [1]
b = [*a, 2, *a]
puts b.size
puts b[2]
c = [0, *b]
puts c.size
puts 12345678901
