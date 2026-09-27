# 64bit の Integer (P8)。PicoRuby の MRB_INT64 と同じく、64bit に入らない結果は RangeError (bigint は無い)。
# 桁あふれの所は picoruby host の出力と比べる (CRuby は Bignum に上がるので比べない)
MAX = 9223372036854775807
MIN = -MAX - 1

def try
  puts yield.inspect
rescue RangeError => e
  puts "#{e.class}: #{e.message}"
end

# リテラルと表示 (32bit に入らないものは LOADI64)
puts MAX, MIN, 4294967296, -2147483649, 0xFFFFFFFF
puts MAX.to_s(16), (1 << 40).to_s(2).size, MIN.to_s.size
puts 3000000000 * 3, 12345678912345 % 1000, 2**40 / 3, -7 / 2, -7 % 2

# 命令 (ADD SUB MUL ADDI) の桁あふれ
try { MAX + 1 }
try { MIN - 1 }
try { MAX * 2 }
try { x = MAX; x += 1 }
try { 4611686018427387904 + 4611686018427387904 }
# メソッドとして呼んだ演算と / の桁あふれ
try { MAX.send(:+, 1) }
try { MAX.send(:-, -1) }
try { MAX.send(:*, 2) }
try { MIN / -1 }
try { MIN % -1 }
try { -MIN }
try { MIN.abs }
# シフトと累乗
try { 1 << 62 }
try { 1 << 63 }
try { -1 << 63 }
try { -1 << 64 }
try { 0 << 64 }
try { 1 >> 64 }
try { -1 >> 100 }
try { 2**62 }
try { 2**63 }
try { (-2)**63 }
# Float との変換
try { MAX.to_f }
try { 9.2e18.to_i }
try { 1e19.to_i }
try { 9.3e18.floor }
try { 9.3e18.truncate }
try { 9.3e18.round }
try { -9.3e18.round }
try { MIN.to_f.to_i }
# 文字列から
try { "9223372036854775807".to_i }
try { "-9223372036854775808".to_i }
try { "9223372036854775808".to_i }
try { "%d" % MIN }
# 桁あふれを rescue して続ける
n = 1
steps = 0
begin
  loop do
    n *= 3
    steps += 1
  end
rescue RangeError
  puts "3**#{steps} = #{n}"
end
$LED = steps
