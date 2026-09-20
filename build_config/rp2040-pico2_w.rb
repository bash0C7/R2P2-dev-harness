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
  conf.gem gemdir: "#{HARNESS_ROOT}/gems/picoruby-ble-dev-bridge"

  # picoruby-ble / picoruby-ble-uart are already in upstream's own
  # r2p2-picoruby-pico2_w.rb (loaded above). picoruby-dfu is not — it's the
  # A/B-slot OTA updater examples/rp2040/ble_dev_bridge.rb needs to accept
  # whole-file app updates over BLE::UART. See
  # docs/research/picoruby-ble-dfu-survey.md and
  # docs/superpowers/plans/2026-09-20-ios-dev-harness-app.md (Task 1).
  #
  # Its declared dependencies (picoruby-env/-yaml/-crc, mruby-pack — read
  # straight from mrbgem.rake, not the README, which lists a stale
  # picoruby-vfs dependency that isn't actually there) all either have an
  # rp2040 port or are VM-only/pure-Ruby, and picoruby-dfu's own upstream
  # test suite (46 assertions) passes on a host build. mruby's gem
  # dependency resolution is expected to pull all of them in on its own,
  # same as it did on host, without needing separate conf.gem lines here.
  #
  # STILL UNVERIFIED: this session has no arm-none-eabi-gcc and no Pico 2 W,
  # so `rake rp2040:build` has never actually run with this line present,
  # and rp2040's littlefs-backed File I/O is a different port than the
  # posix one the host test suite exercised. If the cross-build still fails
  # on a missing gem, that would mean the dependency resolution behaves
  # differently for a CrossBuild than it did here — read the error rather
  # than assume it's the same gap the survey doc already ruled out.
  conf.gem core: 'picoruby-dfu'
end
