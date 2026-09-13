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
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-cdc-midi"
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-usb-peripheral-hid-mouse"
end
