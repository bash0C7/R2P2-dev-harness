# 文字列と出力: puts / print / p、式展開、Integer#to_s、inspect
name = "PERIDOT"
n = 3
puts "Hello, #{name}!"
puts "#{n} + #{n * 2} = #{n + n * 2}"
print "no newline", " ", 42, "\n"
p 1, :sym, "q\"uote", nil, true, [1, "a", [:b]]
puts [1, [2, 3]], nil
puts
puts -123, 0, 2147483647
x = p(7)
$LED = x
puts "日本語 #{name.size}"
$LED = "日本語".size
