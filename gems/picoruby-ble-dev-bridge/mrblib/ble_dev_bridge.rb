# iOS 開発ハーネスアプリ向けの BLE UART フレーマ。
#
# BLE::UART の1本の接続で「REPL の1行」と「DFU::Updater 向けのバイナリペイロード」
# を両方受けるための、バイトの出し入れだけをする器。BLE にも DFU にも Sandbox にも
# 触らない — 依存はゼロ。実際に BLE::UART / DFU::Updater / Sandbox を配線するのは
# examples/rp2040/ble_dev_bridge.rb の役目
# (docs/superpowers/plans/2026-09-20-ios-dev-harness-app.md)。
#
# モード遷移:
#   :repl (既定) -- 改行までを1行として #feed が返す。ただし buffer の先頭が
#                   MAGIC ("DFU\0", picoruby-dfu の DFU::Updater::MAGIC と同じ
#                   4バイト) と一致した時点で :dfu へ切り替わる
#   :dfu         -- 呼び出し側が渡す block (dfu_total) が「あと何バイトで
#                   1件ぶん揃うか」を返すまで貯め続け、揃ったらペイロードを
#                   返して :repl に戻る
#
# 「あと何バイト要るか」を dfu_total という block で外から渡す形にしているのは、
# DFU のヘッダ書式(19バイト固定 + 署名長、picoruby-dfu の README 参照)を
# この gem に持たせないため。書式を知っているのは
# `DFU::Updater.expected_size` で、呼び出し側がそれを渡す。
module BleDevBridge
  class Framer
    MAGIC = "DFU\0"

    def initialize
      @mode = :repl
      @buf = ""
    end

    attr_reader :mode

    # bytes を貯めて、切り出せるものが1つあれば返す。無ければ nil。
    # 1呼び出しにつき最大1件しか返さない — 呼び出し側は nil が返るまでループする
    # (BLE::UART#read_nonblock は1回で全部読めるとは限らないため)。
    #
    # 戻り値:
    #   [:line, "コード文字列"]     mode が :repl の間に見つかった1行(改行抜き)
    #   [:dfu_payload, "バイト列"]  mode が :dfu の間に揃った1件ぶんのペイロード
    #   nil                         まだ何も切り出せない
    def feed(bytes, &dfu_total)
      @buf << bytes if bytes
      case @mode
      when :repl
        if MAGIC.bytesize <= @buf.bytesize && @buf.byteslice(0, MAGIC.bytesize) == MAGIC
          @mode = :dfu
          feed(nil, &dfu_total)
        elsif (idx = @buf.index("\n"))
          line = @buf.byteslice(0, idx)
          @buf = @buf.byteslice((idx + 1)..-1) || ""
          [:line, line]
        end
      when :dfu
        total = dfu_total ? dfu_total.call(@buf) : nil
        if total && total <= @buf.bytesize
          payload = @buf.byteslice(0, total)
          @buf = @buf.byteslice(total..-1) || ""
          @mode = :repl
          [:dfu_payload, payload]
        end
      end
    end
  end
end
