# 実在の PicoRuby プログラムが FPGA コアでどこまで動くかを測る (rake fpga:gap)。
#
# 対象は vendor/picoruby の gem の example と examples/ と fpga/corpus/。1本ずつ mrbc にかけ、
# 変換を止める理由を「最初の1つ」ではなく全部数える (命令、メソッド、pool、catch handler、require)。
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

  # クラスの本体で変換器が読んで、実行時は何もしない呼び出し (rom.rb の noops)。attr_* は名前を定義する
  ATTRS = %w[attr_reader attr_writer attr_accessor].freeze
  DECLARATIONS = (ATTRS + %w[include private public protected module_function]).freeze
  ROOT = File.expand_path("../..", __dir__)

  def targets
    vendor = Dir[File.join(ROOT, "vendor/picoruby/mrbgems/*/{example,examples,sample}/**/*.rb")]
    vendor.reject! { |f| File.basename(f).start_with?("cruby_") }
    (vendor + Dir[File.join(ROOT, "examples/**/*.rb")] + Dir[File.join(ROOT, "fpga/corpus/*.rb")]).sort
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
    c = OUT_OF_SCOPE_CONSTS.find { |k| src =~ /\b#{k}\b/ }
    c && "uses #{c}"
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
        loaded[insn.operands[0]] = ir.syms[insn.operands[1]] if insn.name == "LOADSYM"
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
    FpgaIsa::PRIMS.each { |pr| defined[pr[1]] = true }
    found = {}
    ireps.each_with_index do |ir, i|
      found["pool (strings / big integers)"] = true if ir.plen > 0
      found["catch handler (rescue / ensure)"] = true if ir.clen > 0
      decoded[i].each do |insn|
        found["op #{insn.name}"] = true unless FpgaIsa.convertible?(insn.name)
        next unless %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].include?(insn.name)
        sym = ir.syms[insn.operands[1]]
        next if defined[sym]
        next if %w[block_given? require].include?(sym)
        found["method #{sym}"] = true
      end
    end
    found.keys
  end

  # 1本を調べる。{ path:, status: :out_of_scope / :blocked / :converted, reasons: [...], hex: }
  def check(path, mrbc:, dir:)
    src = File.read(path, encoding: "UTF-8").scrub
    oos = out_of_scope(src)
    return { path: path, status: :out_of_scope, reasons: [oos] } if oos

    bin = begin
      FpgaCorpus.compile(path, mrbc).first
    rescue FpgaCorpus::Error => e
      return { path: path, status: :blocked, reasons: ["mrbc: #{e.message.lines[1].to_s.strip}"] }
    end
    reasons = requires(src).map { |r| "require #{r}" } + blockers(bin)
    return { path: path, status: :blocked, reasons: reasons } unless reasons.empty?

    image = FpgaRom.from_binary(bin, rel(path), FpgaIsa::RF_SIZE)
    hex = File.join(dir, File.basename(path, ".rb") + ".hex")
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
