# ホストでテストを回すための build_config。
#
# upstream の build_config/picoruby-test.rb をそのまま読み込み、
# ハーネスの gem を conf.gem gemdir: で足すだけ。upstream の内容は複製しない
# (複製すると upstream の変更に追従できず、静かに古くなる)。
#
#   MRUBY_CONFIG=<harness>/build_config/host-test.rb rake all   # vendor/picoruby の中で
#
# MRUBY_ROOT は vendor/picoruby の Rakefile がこの config を load する前に定義する。

HARNESS_ROOT = File.expand_path("..", __dir__)

load "#{MRUBY_ROOT}/build_config/picoruby-test.rb"

MRuby.each_target do |conf|
  # FPGA の変換器 (tools/fpga/rom.rb) はこの picoruby で走る。既定の 6.4MB のヒープでは、表示器の gem を入れた
  # プログラム (SSD1306 のデモなど) の変換で NoMemoryError になったので、estalloc の 24bit の番地に収まる 16MB 弱にする
  conf.cc.defines << "HEAP_SIZE=16000000"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-cdc-midi"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-hid-mouse"
  # BLE にも DFU にも依存しない純粋なバッファ操作なのでホストだけで検証できる。
  # docs/superpowers/plans/2026-09-20-ios-dev-harness-app.md 参照。
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-ble-dev-bridge"
end
