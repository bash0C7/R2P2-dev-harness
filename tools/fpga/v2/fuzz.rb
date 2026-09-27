# v2 の差分ファズ (rake fpga:v2:fuzz[count,seed]、計画 V2)。乱数で mruby ソースコードのプログラムを作り、host の PicoRuby と
# 参照 v2 + firmware で走らせて、コンソールの出力を比べる。v1 のファズ (命令の列を作って参照と RTL を比べる) と違い、
# 基準は host (mruby の本物の意味)。作るものは段ごとに足す (V2a: 整数の演算・比較・while・if・def と引数・puts)
require "open3"
require "tmpdir"
require_relative "build"

module FpgaV2
  module Fuzz
    Result = Struct.new(:ok, :src, :host, :ref, :stats, keyword_init: true)

    module_function

    # 1本の mruby ソースコード
    def program(rng)
      lines = []
      vars = %w[a b c]
      vars.each { |v| lines << "#{v} = #{literal(rng)}" }
      defs = []
      rng.rand(1..3).times do |k|
        name = "m#{k}"
        kind = %i[req opt rest].sample(random: rng)
        params = case kind
                 when :req then "x, y"
                 when :opt then "x, y = #{literal(rng)}"
                 when :rest then "x, *r"
                 end
        body = kind == :rest ? "x + r.size" : expr(rng, %w[x y], 2)
        lines << "def #{name}(#{params})\n  #{body}\nend"
        defs << [name, kind]
      end
      rng.rand(4..10).times { lines << statement(rng, vars, defs) }
      lines.join("\n") + "\n"
    end

    def literal(rng)
      case rng.rand(6)
      when 0 then rng.rand(-3..3).to_s
      when 1 then rng.rand(-300..300).to_s
      when 2 then rng.rand(-(2**31)..(2**31)).to_s
      when 3 then [2**62, -(2**62), 2**63 - 1, -(2**63) + 1].sample(random: rng).to_s
      else rng.rand(0..20).to_s
      end
    end

    def expr(rng, vars, depth)
      return (rng.rand(3).zero? ? literal(rng) : vars.sample(random: rng)) if depth.zero? || rng.rand(3).zero?
      l = expr(rng, vars, depth - 1)
      r = expr(rng, vars, depth - 1)
      case rng.rand(8)
      when 0..2 then "(#{l} #{%w[+ - *].sample(random: rng)} #{r})"
      when 3 then "(#{l} / ((#{r}) | 1))" # 0 では割らない (-1 で割ると INT_MIN で桁あふれ、それも比べる)
      when 4 then "(#{l} % ((#{r}) | 1))"
      when 5 then "(#{l} #{%w[& | ^].sample(random: rng)} #{r})"
      when 6 then "(-#{l})"
      else "(#{l} #{%w[< <= > >= == !=].sample(random: rng)} #{r} ? #{literal(rng)} : #{literal(rng)})"
      end
    end

    def call(rng, vars, defs)
      name, kind = defs.sample(random: rng)
      args = case kind
             when :req then [expr(rng, vars, 1), expr(rng, vars, 1)]
             when :opt then [expr(rng, vars, 1)] + (rng.rand(2).zero? ? [] : [expr(rng, vars, 1)])
             when :rest then Array.new(rng.rand(1..4)) { expr(rng, vars, 1) }
             end
      "#{name}(#{args.join(', ')})"
    end

    def statement(rng, vars, defs)
      v = vars.sample(random: rng)
      case rng.rand(7)
      when 0, 1 then "#{v} = #{expr(rng, vars, 2)}"
      when 2 then "puts #{expr(rng, vars, 2)}"
      when 3 then "puts #{call(rng, vars, defs)}"
      when 4 then "i = 0\nwhile i < #{rng.rand(1..5)}\n  #{v} = #{expr(rng, vars, 1)}\n  puts #{v}\n  i += 1\nend"
      when 5 then "if #{expr(rng, vars, 1)} #{%w[< > ==].sample(random: rng)} #{literal(rng)}\n  puts #{v}\nelse\n  puts #{%w[true false nil 1].sample(random: rng)}\nend"
      else "puts #{vars.map { |x| x }.join(', ')}"
      end
    end

    # 1本を host と参照で走らせて比べる
    def check(src, picoruby:)
      Dir.mktmpdir do |dir|
        rb = File.join(dir, "fuzz.rb")
        File.write(rb, src)
        host, = Open3.capture2e("timeout", "10", picoruby, rb)
        host = host.lines.take_while { |l| !l.start_with?("trace (most recent call last)") }.join # 例外は stderr と同じ所に出るので切る
        ref, st = Build.run_source(src, max_steps: 20_000_000)
        Result.new(ok: host.b == ref, src: src, host: host, ref: ref, stats: st.stats)
      end
    end
  end
end
