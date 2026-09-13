# Pico 2 W の firmware 用 build_config。
#
# upstream の build_config/r2p2-picoruby-pico2_w.rb をそのまま読み込み、
# ハーネスの gem を足すだけ。build の名前は upstream のものを引き継ぐ
# (upstream の r2p2 rake task が build/<name>/ を名前で探すため)。
#
# この file は vendor/picoruby/build_config/ へ shim 経由で読み込まれる。
# 詳しくは rakelib/vendor.rake の :overlay task を参照。

HARNESS_ROOT = File.expand_path("..", __dir__)

load "#{MRUBY_ROOT}/build_config/r2p2-picoruby-pico2_w.upstream.rb"

MRuby.each_target do |conf|
  next unless conf.name.start_with?("r2p2-picoruby-pico2_w")
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-cdc-midi"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-hid-mouse"
end
