# BLE UART (Nordic UART Service) の1本の接続で、REPL(1行ずつ Sandbox で実行)と
# DFU(app.rb 丸ごと差し替え)の両方を受ける。iOS 開発ハーネスアプリが将来
# CoreBluetooth でここへ繋がる想定の、実機で最初に固める一次ループ。
#
#   ruby <harness>/tools/pico2w/pmput.rb examples/rp2040/ble_dev_bridge.rb /home/app.rb
#
# 配線の判定は BleDevBridge::Framer (gems/picoruby-ble-dev-bridge、依存ゼロで
# ホストのみで検証済み) に切り出してある。ここでは BLE::UART / DFU::Updater /
# Sandbox を Framer の判定に従って呼ぶだけ。
#
# REPL は upstream picoruby-ble-uart の example/ble_irb.rb と同じ形
# (Sandbox#compile → #execute → #result)。DFU 側は picoruby-dfu の
# DFU::Updater を `path: "/home/app.rb"` で使う — A/B スロットは経由せず、
# 開発中の速いイテレーション用に直書きする(A/B スロット経由の安全な更新は
# 別の口を後で用意する。docs/superpowers/specs/2026-09-20-ios-dev-harness-app-design.md
# の「アプリコードの転送・イテレーション」参照)。
#
# 未検証: このファイルは Pico 2 W 実機でまだ動かしていない。
# docs/superpowers/plans/2026-09-20-ios-dev-harness-app.md の Task 3 参照。
require 'ble'
require 'dfu'
require 'ble_dev_bridge'

uart = BLE::UART.new(name: "R2P2")
sandbox = Sandbox.new('ble-dev-bridge')
framer = BleDevBridge::Framer.new
dfu_total = ->(buf) { DFU::Updater.expected_size(buf) }

def run_repl_line(uart, sandbox, code)
  return if code.empty?
  if sandbox.compile("begin; _ = (#{code}); rescue => _; end; _")
    sandbox.execute
    sandbox.wait(timeout: nil)
    sandbox.suspend
    uart.puts "=> #{sandbox.result.inspect}"
  else
    uart.puts "=> SyntaxError"
  end
end

def run_dfu_payload(uart, payload)
  io = BLE::UART::BufferIO.new(payload)
  DFU::Updater.new(path: "/home/app.rb").receive(io)
  uart.puts "OK"
rescue => e
  uart.puts "ERR #{e.message}"
end

uart.start do
  # 1回の tick で新規バイトを1度だけ取り込み、そこから切り出せる単位を
  # framer が nil を返すまで drain する(1つの BLE パケットに複数行や
  # DFU ヘッダの続きがまとまって届くことがあるため)。
  chunk = uart.read_nonblock
  loop do
    unit = framer.feed(chunk, &dfu_total)
    chunk = nil
    break unless unit

    kind, payload = unit
    case kind
    when :line
      run_repl_line(uart, sandbox, payload.chomp)
    when :dfu_payload
      run_dfu_payload(uart, payload)
    end
  end
end
