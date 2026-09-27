# FPGA の変換器 (tools/fpga/{isa,io_map,rite,rom,mrb2rom}.rb、mruby ソースコード) を走らせ、oracle (host の PicoRuby の出力) を取る host の picoruby と mrbc。
# tools/fpga の oracle (host の PicoRuby と出力を比べるテスト) もこの VM で走らせるので、比べる gem (picotest) も入れる。
#
# host のテスト用の VM (host-test.rb、upstream の picoruby-test.rb) は PICORB_DEBUG 付きで、picoruby-machine が ESTALLOC_DEBUG を
# 定義する。すると est_free が解放のたびにヒープの全ブロックを先頭からたどるので、変換器のように生きているオブジェクトの多い
# プログラムは n² で遅い (collections.mrb の変換に 34 秒、CRuby は 0.2 秒。callgrind で est_free が 68%)。
# この VM は PICORB_DEBUG 無し (NDEBUG、-Os) で build する。upstream に debug 無しで picoruby-bin-picoruby を入れた host の
# build_config が無いので、picoruby-test.rb から PICORB_DEBUG を除いたものをここに書く。
#
#   MRUBY_CONFIG=<harness>/build_config/fpga-tools.rb MRUBY_BUILD_DIR=<harness>/build/picoruby-fpga rake all   # vendor/picoruby の中で
#
# (rake fpga:picoruby がそうする。build/picoruby-fpga/host/bin/{picoruby,mrbc} ができる)
MRuby::Build.new do |conf|
  conf.toolchain :gcc

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"
  # 表示器の gem を入れたプログラム (SSD1306 のデモなど) の変換で既定の 6.4MB では NoMemoryError になる (host-test.rb と同じ)
  conf.cc.defines << "HEAP_SIZE=16000000"

  conf.picoruby

  conf.linker.libraries << "ssl"
  conf.linker.libraries << "crypto"

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: "picoruby-bin-picoruby"
  conf.gem core: "picoruby-picotest"

  # oracle (rake fpga:oracle): FPGA で走らせるプログラムと gem の test を、この VM でも走らせて正しい出力を取る。
  # デバイスの gem は ports/posix のあるもの (upstream の rake test と同じ形)。C の所だけの gem と mrblib だけの gem も入れる。
  # i2c・spi・watchdog は posix の port が無く、この VM に入らない (それを使う ssd1306・uc8151 も)。string-bitops は mruby/c 用 (picoruby-mruby と衝突)
  %w[
    picoruby-gpio picoruby-adc picoruby-pwm picoruby-uart picoruby-irq picoruby-psg picoruby-io-console
    picoruby-vram picoruby-bdffont picoruby-midibase picoruby-midibase-mml picoruby-uart-midi
    picoruby-rotary_encoder picoruby-hcsr04 picoruby-median_filter picoruby-uri
    picoruby-picooptparse picoruby-markdown
  ].each { |g| conf.gem core: g }
end
