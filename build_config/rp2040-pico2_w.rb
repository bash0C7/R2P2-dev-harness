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
  # test suite (46 assertions) passes on a host build.
  #
  # `rake rp2040:build` WITH this line HAS been run for real in this
  # session (arm-none-eabi-gcc installed via apt for the occasion) and
  # produced a real .uf2 — `strings` on the resulting .elf shows both
  # `gem_mrblib_picoruby_ble_dev_bridge_proc_*` symbols and picoruby-dfu's
  # own error strings (e.g. `, expected "DFU\0")`), confirming both gems
  # actually compiled and linked in, not just "the build didn't crash".
  # See docs/research/picoruby-ble-dfu-survey.md for the full picture.
  #
  # STILL UNVERIFIED: this only proves it *builds*. Nothing has flashed or
  # booted this image on real silicon (still needs a Pico 2 W, per the
  # plan's Task 3) — rp2040's littlefs-backed File I/O is a different port
  # than the posix one the host test suite exercised, and the BLE/BTstack
  # stack has never actually powered on and talked to a real radio.
  conf.gem core: 'picoruby-dfu'
end
