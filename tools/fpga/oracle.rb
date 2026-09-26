# 参照インタプリタ自体の正しさを、別の実装で確かめるための道具。
#
# - CRuby: 同じ .rb を CRuby で走らせ、trace_var で I/O のグローバル変数への代入を拾う。
#   入力 (in ポート) を読むプログラムは step と対応付けられないので対象外。
#   無限ループのプログラムは、代入を limit 回拾ったところで打ち切る。sleep_ms / sleep は待たない
# - picoruby host VM: 同じ compiler・同じ VM の本物の意味。代入の系列は取れないので、
#   止まるプログラムの最後の値だけを `p` で出させて比べる
require "open3"
require "tmpdir"
require "rbconfig"
require_relative "converter"

module FpgaOracle
  class Error < StandardError; end

  module_function

  # [[port, value], ...] (value は Integer / true / false / nil)
  def cruby_writes(src_path, limit:)
    outs = FpgaIoMap::PORTS.select { |p| p.dir == :out }
    # 時間待ちは待たずに引数を返す (コアと参照インタプリタも値はそうしている。待つ長さはボードエミュレーターで見る)
    script = +"def sleep_ms(n) = n\ndef sleep(n) = n\n$__w = []\n"
    outs.each do |p|
      script << "trace_var(:#{p.name}) { |v| $__w << [#{p.num}, v]; throw :__stop if $__w.size >= #{limit} }\n"
    end
    script << "catch(:__stop) { load #{File.expand_path(src_path).inspect} }\n"
    script << "STDOUT.write Marshal.dump($__w)\n"
    out, err, st = Open3.capture3(RbConfig.ruby, "-e", script)
    raise Error, "CRuby failed on #{src_path}: #{err}" unless st.success?
    Marshal.load(out)
  end

  # 出力ポートの最後の値 {port => value}
  def picoruby_final(src_path, picoruby:)
    outs = FpgaIoMap::PORTS.select { |p| p.dir == :out }
    src = File.read(src_path) + "\np [#{outs.map(&:name).join(', ')}]\n"
    Dir.mktmpdir do |dir|
      path = File.join(dir, File.basename(src_path))
      File.write(path, src)
      out, err, st = Open3.capture3(picoruby, path)
      raise Error, "picoruby failed on #{src_path}: #{err}#{out}" unless st.success?
      values = parse_inspect(out.lines.last.to_s.strip)
      outs.map(&:num).zip(values).to_h
    end
  end

  # `p [1, nil, true]` の出力を読む (Integer / true / false / nil だけ)
  def parse_inspect(line)
    raise Error, "unexpected picoruby output: #{line.inspect}" unless line.start_with?("[") && line.end_with?("]")
    line[1..-2].split(",").map(&:strip).map do |t|
      case t
      when "nil" then nil
      when "true" then true
      when "false" then false
      when /\A-?\d+\z/ then t.to_i
      else raise Error, "unexpected value #{t.inspect} in #{line.inspect}"
      end
    end
  end
end
