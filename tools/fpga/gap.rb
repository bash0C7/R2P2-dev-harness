# 実在の PicoRuby プログラムが FPGA コアでどこまで動くかを測る (rake fpga:gap)。
#
# 対象は vendor/picoruby の gem の example と test (`test/*_test.rb`) と examples/ と fpga/corpus/。1本ずつ mrbc にかけ、
# 変換を止める理由を「最初の1つ」ではなく全部数える (命令、メソッド、pool、require)。
# ハードウェアに無いもの (ネットワーク、BLE、TLS、ファイル、USB デバイス、コンパイラ) を require するものは範囲外。
# 計画: docs/superpowers/plans/2026-09-26-fpga-full-picoruby.md
require "open3"
require "tmpdir"
require_relative "converter"
require_relative "corpus"

module FpgaGap
  module_function

  # PERIDOT-Air に無いものを使う gem。これを require するプログラムは範囲外:
  # 無線と通信 (socket net/* drb cyw43 ble quectel_cellular dfu)、USB デバイス (usb/* keyboard)、
  # TLS と暗号 (C の mbedTLS の上にある)、ファイルシステム、コンパイラ (prism sandbox)、ホストの CLI (optparse)
  OUT_OF_SCOPE = %w[
    socket net/websocket net/ntp net/mqtt net/http drb cyw43 ble quectel_cellular dfu
    usb/cdc/midi usb/hid usb/peripheral/cdc_midi keyboard keyboard_matrix
    openssl jwt mbedtls vfs filesystem prism sandbox optparse
  ].freeze

  # 範囲外の gem の中のクラス (require を書かずに使う example もある)
  OUT_OF_SCOPE_CONSTS = %w[TCPSocket TCPServer UDPSocket SSLSocket SSLContext BLE CYW43 DRb MbedTLS Prism Keyboard].freeze
  # host (CRuby) で走る係。板の上では走らない (Picotest::Runner はテストのファイルを探し、一時スクリプトを作って VM を起こす)
  HOST_SIDE_CONSTS = %w[Picotest::Runner].freeze

  # クラスの本体で変換器が読んで、実行時は何もしない呼び出し (rom.rb の noops)。attr_* は名前を定義する
  ATTRS = %w[attr_reader attr_writer attr_accessor].freeze
  DECLARATIONS = (ATTRS + %w[include private public protected module_function]).freeze
  ROOT = File.expand_path("../..", __dir__)
  # PicoRuby の gem が、使う側 (プログラム) が定義する前提で呼ぶメソッド (ADC#init_additional_params)
  HOOKS = %w[init_additional_params].freeze

  # FPGA 版の gem (と使う PicoRuby の mrblib) のどれかが定義するメソッドの名前。gem の中の呼び出しが、受け手の型しだいで
  # 別の gem のメソッドになるもの (MIDIBASE::Session の player の next_event など) を止める理由に数えないため
  def gem_methods
    @gem_methods ||= FpgaCorpus::GEMS.values.flat_map { |files, _| Array(files) }.flat_map do |f|
      src = File.read(File.expand_path(f, FpgaCorpus::GEMS_DIR))
      src.scan(/^\s*(?:private\s+)?(?:def\s+(?:self\.)?|alias\s+)([a-z_]\w*[?!=]?)/).flatten +
        src.scan(/^\s*attr_(?:reader|accessor)\s+(.*)$/).flatten.flat_map { |l| l.scan(/:(\w+)/).flatten }
    end.uniq
  end

  def targets
    vendor = Dir[File.join(ROOT, "vendor/picoruby/mrbgems/*/{example,examples,sample}/**/*.rb")]
    vendor.reject! { |f| File.basename(f).start_with?("cruby_") }
    tests = Dir[File.join(ROOT, "vendor/picoruby/mrbgems/*/test/*_test.rb")]
    (vendor + tests + Dir[File.join(ROOT, "examples/**/*.rb")] + Dir[File.join(ROOT, "fpga/corpus/*.rb")]).sort
  end

  # gem のテスト (mrbgems/<gem>/test/*_test.rb) の頭。upstream の rake test (tasks/picoruby/test.rake) の Picotest::Runner と同じく
  # picotest と、その gem の require の名前 (mrbgem.rake の spec.require_name、無ければ gem の名前から picoruby- を除いたもの) を
  # require する。Runner の Kernel#require の包み (LoadError を無視) は付けない: FPGA の require は変換の時に解くので、
  # FPGA 版の gem が無ければ止まる理由に出す。gem のテストでなければ nil
  def gem_test_head(path)
    m = path.match(%r{/mrbgems/([^/]+)/test/[^/]+_test\.rb\z}) or return nil
    rake = File.join(ROOT, "vendor/picoruby/mrbgems", m[1], "mrbgem.rake")
    name = File.exist?(rake) && File.read(rake)[/^\s*spec\.require_name\s*=\s*["']([^"']+)["']/, 1]
    "require 'picotest'\nrequire '#{name || m[1].delete_prefix("picoruby-")}'\n"
  end

  def rel(path)
    path.sub("#{ROOT}/", "")
  end

  def requires(src)
    src.scan(/^\s*require\s*\(?\s*["']([^"']+)["']/).flatten
  end

  # 範囲外なら理由 ("require socket" など)、範囲内なら nil
  def out_of_scope(src)
    r = requires(src).find { |name| OUT_OF_SCOPE.include?(name) }
    return "require #{r}" if r
    code = src.gsub(/^\s*#.*$/, "") # 行全体の注釈の中の名前は数えない
    c = OUT_OF_SCOPE_CONSTS.find { |k| code =~ /\b#{k}\b/ }
    return "uses #{c}" if c
    h = HOST_SIDE_CONSTS.find { |k| code.include?(k) }
    h && "host side: #{h}"
  end

  # picotest のテストのファイル (Picotest::Test の子クラスを定義するだけ) に、Picotest::Runner が板の VM に渡すスクリプトと同じ
  # 末尾を付ける (test_* を1つずつ呼び、最後に "----" と結果の JSON)。テストのファイルでなければ nil
  def picotest_tail(src)
    classes = []
    src.each_line do |l|
      if (m = l.match(/^\s*class\s+(\w+)\s*<\s*Picotest::Test\b/))
        classes << [m[1], []]
      elsif (m = l.match(/^\s*def\s+(test_\w+)/)) && !classes.empty?
        classes.last[1] << m[1]
      end
    end
    return nil if classes.empty?
    classes.map do |klass, tests|
      body = tests.map do |t|
        <<~T
          puts
          print '  #{klass}##{t} '
          begin
            my_test.setup
            my_test.#{t}
          rescue Picotest::Skip => e
            my_test.report_skip({method: '#{t}', reason: e.message})
          rescue => e
            my_test.report_exception({method: '#{t}', raise_message: e.message})
          ensure
            my_test.teardown
            my_test.clear_doubles
          end
        T
      end.join
      "\nmy_test = #{klass}.new\nputs\nprint 'From #{klass}:'\n#{body}puts\nputs \"----\"\nputs JSON.generate(my_test.result)\n"
    end.join
  end

  # 変換を止める理由を全部 (重複なし)。["op STRING", "method puts", "pool", ...]
  def blockers(bin)
    top = Rite.parse(bin)
    ireps = FpgaRom.flatten(top, [])
    decoded = ireps.map { |ir| Rite.decode(ir.iseq) }
    defined = {}
    ireps.each_with_index do |ir, i|
      loaded = {} # レジスタ -> 直前の LOADSYM の名前 (attr_* の引数)
      decoded[i].each do |insn|
        defined[ir.syms[insn.operands[1]]] = true if %w[TDEF DEF SDEF].include?(insn.name)
        defined[ir.syms[insn.operands[0]]] = true if insn.name == "ALIAS" # alias 新 旧
        loaded[insn.operands[0]] = ir.syms[insn.operands[1]] if insn.name == "LOADSYM"
        if insn.name == "SSEND" && ir.syms[insn.operands[1]] == "alias_method" # alias_method :新, :旧
          name = loaded[insn.operands[0] + 1]
          defined[name] = true if name
        end
        next unless insn.name == "SSEND" && ATTRS.include?(ir.syms[insn.operands[1]])
        (insn.operands[2] & 0xF).times do |j|
          name = loaded[insn.operands[0] + 1 + j]
          next unless name
          defined[name] = true unless ir.syms[insn.operands[1]] == "attr_writer"
          defined["#{name}="] = true unless ir.syms[insn.operands[1]] == "attr_reader"
        end
      end
    end
    DECLARATIONS.each { |n| defined[n] = true }
    HOOKS.each { |n| defined[n] = true }
    gem_methods.each { |n| defined[n] = true }
    FpgaIsa::PRIMS.each { |pr| defined[pr[1]] = true }
    found = {}
    ireps.each_with_index do |ir, i|
      ir.pool.each do |e|
        found["big integer literal"] = true if e[0] == :bigint || (e[0] == :int && (e[1] < -2**63 || e[1] >= 2**63))
      end
      decoded[i].each do |insn|
        found["op #{insn.name}"] = true unless FpgaIsa.convertible?(insn.name)
        next unless %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(insn.name)
        sym = ir.syms[insn.operands[1]]
        next if defined[sym]
        next if %w[block_given? require].include?(sym)
        next if sym.start_with?("__") # プレリュードの中身 (わざと未定義にして止めるものも)
        found["method #{sym}"] = true
      end
    end
    found.keys
  end

  # 1本を調べる。{ path:, status: :out_of_scope / :blocked / :converted, reasons: [...], hex: }
  def check(path, mrbc:, dir:)
    src = File.read(path, encoding: "UTF-8").scrub
    head = gem_test_head(path)
    src = head + src if head
    oos = out_of_scope(src)
    return { path: path, status: :out_of_scope, reasons: [oos] } if oos

    tail = picotest_tail(src)
    if tail || head
      # Runner と同じ頭と末尾を付けた写しを compile する (gem のテストでなければ頭は require 'picotest' だけ)
      copy = File.join(dir, rel(path).tr("/", "_"))
      File.write(copy, (head ? "" : "require 'picotest'\n") + src + tail.to_s)
      path_for_compile = copy
    else
      path_for_compile = path
    end
    bin = begin
      FpgaCorpus.compile(path_for_compile, mrbc, strict: false).first
    rescue FpgaCorpus::Error => e
      return { path: path, status: :blocked, reasons: ["mrbc: #{e.message.lines[1].to_s.strip}"] }
    end
    # FPGA 版の gem がある require は止める理由にしない (gem は compile の時に前に置いた)
    reasons = requires(src).reject { |r| FpgaCorpus::GEMS[r] }.map { |r| "require #{r}" } + blockers(bin)
    return { path: path, status: :blocked, reasons: reasons } unless reasons.empty?

    image = FpgaRom.from_binary(bin, rel(path), FpgaIsa::RF_SIZE)
    hex = File.join(dir, rel(path).tr("/", "_").delete_suffix(".rb") + ".hex") # 同じ basename の example があるので path から (並べて回す)
    File.write(hex, image.hex)
    { path: path, status: :converted, reasons: [], hex: hex }
  rescue FpgaRom::Error, Rite::Error => e
    { path: path, status: :blocked, reasons: ["convert: #{e.message.sub(/\A[^:]*: /, '')}"] }
  end

  # 止まる理由を多い順に [[理由, 本数], ...]
  def histogram(results)
    h = Hash.new(0)
    results.each { |r| r[:reasons].each { |x| h[x.sub(/\Aconvert: .*/, 'convert error')] += 1 } if r[:status] == :blocked }
    h.sort_by { |k, v| [-v, k] }
  end
end
