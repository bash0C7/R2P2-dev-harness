# 正しさの基準 (oracle)。
#
# - 全部のプログラム (rake fpga:oracle と fpga:gap): プログラムを host の PicoRuby (tools の VM、build_config/fpga-tools.rb、
#   R2P2 と同じ MRB_INT64) で走らせた出力。FPGA のコアの出力は、参照 (ref_vm.rb) と一致するだけでなく、これと同じでなければならない
#   (docs/superpowers/plans/2026-09-27-fpga-v2.md)。走らせ方は gap と同じ: gem の test は upstream の rake test の Runner と同じ頭
#   (require 'picotest' と gem の require の名前) と末尾 (test_* を1つずつ呼んで JSON)、picotest のテストのファイルは末尾だけ。
#   止まらないプログラム (blink の loop など) は TIMEOUT 秒で切り、それまでの出力を取る (:timeout)。host では stdout を pipe にすると
#   C の stdio が溜めるので stdbuf で行ごとに出させる
# - 参照インタプリタ自体の正しさを、別の実装で確かめるための道具 (ref_vm_test):
# - CRuby: 同じ .rb を CRuby で走らせ、trace_var で I/O のグローバル変数への代入を拾う。
#   入力 (in ポート) を読むプログラムは step と対応付けられないので対象外。
#   無限ループのプログラムは、代入を limit 回拾ったところで打ち切る。sleep_ms / sleep は待たない
# - picoruby host VM: 同じ compiler・同じ VM の本物の意味。代入の系列は取れないので、
#   止まるプログラムの最後の値だけを `p` で出させて比べる
require "open3"
require "tmpdir"
require "rbconfig"
require_relative "converter"
require_relative "corpus"
require_relative "gap"
require "json"
require "fileutils"

module FpgaOracle
  class Error < StandardError; end

  module_function

  # CRuby 3.3 の Hash#inspect ({"a"=>1, :b=>2}) を PicoRuby の形 ({"a" => 1, b: 2}) にする。プレリュードも PicoRuby に合わせる
  HASH_INSPECT = <<~'RUBY'
    class Hash
      def inspect
        "{" + map { |k, v| (k.is_a?(Symbol) ? "#{k}: " : "#{k.inspect} => ") + v.inspect }.join(", ") + "}"
      end
      alias to_s inspect
    end
  RUBY

  # CRuby 3.3 の Exception#inspect (メッセージが無くても #<TypeError: TypeError>) を PicoRuby の形 (TypeError) にする。
  # PicoRuby はメッセージが nil か空の時にクラスの名前だけを出す。CRuby ではメッセージが無いとクラスの名前になるので、それで見分ける
  EXC_INSPECT = <<~'RUBY'
    class Exception
      def inspect
        m = to_s
        m.empty? || m == self.class.name ? self.class.name : "#<#{self.class.name}: #{m}>"
      end
    end
  RUBY

  # [[port, value], ...] (value は Integer / true / false / nil)。console ポートは除く (cruby_run の2つ目)
  def cruby_writes(src_path, limit:)
    cruby_run(src_path, limit: limit)[0]
  end

  # [ピンへの代入の系列, 標準出力 (console に出るはずのもの)]。代入を limit 回拾ったら打ち切る
  def cruby_run(src_path, limit:)
    outs = FpgaIoMap.pins_out
    # 時間待ちは待たずに引数を返す (コアと参照インタプリタも値はそうしている。待つ長さはボードエミュレーターで見る)
    script = +"require \"stringio\"\ndef sleep_ms(n) = n\ndef sleep(n) = n\n$__w = []\n"
    script << HASH_INSPECT << EXC_INSPECT
    # デバイス: 参照インタプリタと同じモデル (devices.rb) で __io_read / __io_write を定義し、FPGA 版の gem を読む。
    # 書き込みはピンへの代入と同じ列に入れる (値は 64bit の符号付きにそろえる)。時間は 0 (命令の数が無い)
    script << "require #{File.expand_path('devices', __dir__).inspect}\n$__dev = FpgaDevices::Bank.new([])\n"
    script << "def __s64(v) = (v & (2**64 - 1)) >= 2**63 ? (v & (2**64 - 1)) - 2**64 : (v & (2**64 - 1))\n"
    # CRuby には命令の区切りが無いので、デバイスの tick (IRQ の事象) は読み書きのたびに (出力のピンの変化は次のアクセスで見える)
    script << "def __io_read(a) = ($__dev.tick(0, 0); $__dev.read(a, 0, 0))\n"
    script << "def __io_write(a, v)\n  $__dev.tick(0, 0)\n  $__w << [a, v.is_a?(Integer) ? __s64(v) : v]; throw :__stop if $__w.size >= #{limit}\n" \
              "  $__dev.write(a, v & 0xFFFF_FFFF) if v.is_a?(Integer)\n  v\nend\n"
    script << "def require(name) = true\n"
    FpgaCorpus.gem_files(src_path).each { |g| script << "load #{g.inspect}\n" }
    outs.each do |p|
      script << "trace_var(:#{p.name}) { |v| $__w << [#{p.num}, v]; throw :__stop if $__w.size >= #{limit} }\n"
    end
    script << "$stdout = StringIO.new\n"
    script << "catch(:__stop) { load #{File.expand_path(src_path).inspect} }\n"
    script << "STDOUT.write Marshal.dump([$__w, $stdout.string])\n"
    out, err, st = Open3.capture3(RbConfig.ruby, "-e", script)
    raise Error, "CRuby failed on #{src_path}: #{err}" unless st.success?
    Marshal.load(out)
  end

  # 出力ポート (ピン) の最後の値 {port => value}
  def picoruby_final(src_path, picoruby:)
    picoruby_run(src_path, picoruby: picoruby)[0]
  end

  # [ピンの最後の値 {port => value}, 標準出力 (最後の p の行を除く)]
  def picoruby_run(src_path, picoruby:)
    outs = FpgaIoMap.pins_out
    src = File.read(src_path) + "\np [#{outs.map(&:name).join(', ')}]\n"
    Dir.mktmpdir do |dir|
      path = File.join(dir, File.basename(src_path))
      File.write(path, src)
      out, err, st = Open3.capture3(picoruby, path)
      raise Error, "picoruby failed on #{src_path}: #{err}#{out}" unless st.success?
      lines = out.lines
      values = parse_inspect(lines.last.to_s.strip)
      [outs.map(&:num).zip(values).to_h, lines[0...-1].join]
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

  TIMEOUT = 10
  Result = Struct.new(:path, :status, :out, :err, :seconds, keyword_init: true)

  def default_picoruby = FpgaConverter.default_picoruby

  # host で走らせる mruby ソースコード (gap と同じ頭と末尾)。範囲外なら nil
  def script(path)
    src = File.read(path, encoding: "UTF-8").scrub
    head = FpgaGap.gem_test_head(path)
    src = head + src if head
    return nil if FpgaGap.out_of_scope(src)
    tail = FpgaGap.picotest_tail(src)
    (tail && !head ? "require 'picotest'\n" : "") + src + tail.to_s
  end

  # 1本を host で走らせる。dir に写しを書く (相対の require_relative は範囲外なので path を変えてよい)
  def run(path, dir:, picoruby: default_picoruby, timeout: TIMEOUT)
    s = script(path)
    return Result.new(path: path, status: :out_of_scope, out: "", err: "", seconds: 0) unless s
    copy = File.join(dir, FpgaGap.rel(path).tr("/", "_"))
    File.write(copy, s)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, st = Open3.capture3("timeout", "-s", "KILL", timeout.to_s, "stdbuf", "-o0", "-e0", picoruby, copy, stdin_data: "")
    sec = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    status = if st.termsig == 9 || st.exitstatus == 137 then :timeout
             elsif st.success? then :exit
             else :error
             end
    Result.new(path: path, status: status, out: out.force_encoding("UTF-8").scrub, err: err.force_encoding("UTF-8").scrub, seconds: sec.round(2))
  end

  # host の出力と FPGA の出力 (コンソールのバイト列) を比べる。どちらかが途中で切られた (host の :timeout、FPGA の命令数の上限)
  # なら、短い方が長い方の頭と同じなら :prefix。両方が終わっていれば同じ時だけ :same。
  # host で走らなかった (gem が無い、posix の port が無い機能で raise) ものは基準にならないので :host_error
  def judge(host, fpga_out, fpga_cut:)
    return :host_error if host.status == :error
    return :same if host.out == fpga_out && host.status != :timeout && !fpga_cut
    cut = host.status == :timeout || fpga_cut
    short, long = [host.out, fpga_out].sort_by(&:bytesize)
    return :prefix if cut && long.start_with?(short)
    :differs
  end
end
