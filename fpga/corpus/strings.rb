# String のメソッド (プレリュード)。結果は console と $LED に
s = "Hello World"
$LED = s.size
$LED = s.bytesize
puts s.upcase, s.downcase, s.swapcase, s.reverse
puts s[0], s[-1], s[6, 5], s[3, 100].inspect, s[20].inspect
$LED2 = s.include?("World")
$LED2 = s.start_with?("Hell")
$LED2 = s.end_with?("x")
$LED = s.index("o")
$LED = s.index("o", 5)
puts s.split.inspect, "a,b,,c,,".split(",").inspect, "  x  y ".split(" ").inspect
puts "  pad  ".strip + "|", "line\n".chomp + "|"
puts "ab" * 3, "ab" + "cd", "x".center(7, "*"), "7".rjust(3, "0"), "l".ljust(3) + "|"
$LED = "12abc".to_i
$LED = "-45".to_i
$LED = " 1_000".to_i
$LED = "ff".to_i(16)
t = "abc"
u = t
u << "def" << 33
puts t, t.bytes.inspect, t.chars.inspect
$LED2 = t == "abcdef!"
$LED2 = "a" < "b"
$LED = "héllo".size
puts "héllo"[1], "héllo".reverse, "é".ord
puts "a-b-c".gsub("-", "+"), "a-b-c".sub("-", "+"), "banana".count("an")
puts format("%05d|%-4s|%x|%3d|%+d", 42, "ab", 255, 7, 5), "%s=%d" % ["k", 9]
puts :sym.to_s, :sym.inspect, 65.chr, 255.to_s(2)
puts nil.to_s.empty?, "ok".frozen?.inspect
puts Integer, s.class, 5.class
