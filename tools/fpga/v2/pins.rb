# 板のプログラム (fpga/v2/board/*.rb、終わらない loop) を host と ref で走らせ、仮想の時刻で区切ったピンの変化の列
# (時刻 ms, pin, 値) とコンソールの出力を比べる (計画 S7-1: docs/superpowers/plans/2026-09-28-fpga-v2-s7-gems.md)。
#
# - host: firmware-patches/posix-board-{clock,gpio}.patch を当てた build/picoruby-fpga の picoruby。
#   環境変数 FPGA_BOARD_UNTIL_MS で上限を渡すと、ピンの列を stderr に `pin <ms> <pin> <値>` の行で出し、上限を超える tick の前で exit(0) する
# - ref: tools/fpga/v2/board.rb の Board (同じ板のモデル)
require "open3"
require "tmpdir"
require_relative "build"

module FpgaV2
  module Pins
    DIR = File.join(Build::ROOT, "fpga", "v2", "board")
    UNTIL_MS = 2000
    PIN_LINE = /\Apin (\d+) (\d+) ([01])\z/

    Result = Struct.new(:name, :host_pins, :host_out, :ref_pins, :ref_out, :steps, keyword_init: true) do
      def ok? = host_pins == ref_pins && host_out == ref_out
    end

    module_function

    def programs = Dir[File.join(DIR, "*.rb")].sort

    # LED_PIN は板のモデルの定数 (host と ref で同じ 1 行を頭に足す)
    def source(path) = "LED_PIN = #{Board::LED_PIN}\n" + File.read(path)

    def host(path, until_ms:, picoruby:)
      Dir.mktmpdir do |dir|
        rb = File.join(dir, File.basename(path))
        File.write(rb, source(path))
        out, err, = Open3.capture3({ "FPGA_BOARD_UNTIL_MS" => until_ms.to_s }, picoruby, rb)
        pins = err.lines(chomp: true).filter_map { |l| l.match(PIN_LINE)&.captures&.map(&:to_i) }
        [pins, out.b]
      end
    end

    def ref(path, until_ms:, max_steps: 50_000_000)
      Dir.mktmpdir do |dir|
        rb = File.join(dir, File.basename(path))
        File.write(rb, source(path))
        r = Ref.new(Build.image([Build.compile([rb])]), max_steps: max_steps)
        r.board = Board.new(until_ms: until_ms)
        out = r.run
        [r.board.events, out.b, r]
      end
    end

    def check(path, until_ms: UNTIL_MS, picoruby: FpgaConverter.default_picoruby)
      host_pins, host_out = host(path, until_ms: until_ms, picoruby: picoruby)
      ref_pins, ref_out, r = ref(path, until_ms: until_ms)
      Result.new(name: File.basename(path, ".rb"), host_pins: host_pins, host_out: host_out, ref_pins: ref_pins, ref_out: ref_out, steps: r.steps)
    end

    def format_pins(pins) = pins.map { |ms, pin, v| format("%6d ms  pin %2d  %d", ms, pin, v) }
  end
end
