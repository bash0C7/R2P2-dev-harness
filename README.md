# R2P2-dev-harness

bash0C7 が個人で **PicoRuby の装置を作るための知見と rake タスクを集約する** repo。

知見も rake タスクも R2P2-darwin / R2P2-ESP32 / picoruby/picoruby / picoruby-ble-verify などに
散らばっているので、1箇所に集める。中心は実機を焼く・転送する・走らせる・再起動する rake タスク
(`rake rp2040:*`、`rake esp32:*`) と、実機で踏んだ罠 ([docs/spec.md](docs/spec.md) §6 と §9)。

PicoRuby を USB 周辺機器にするライブラリ (`gems/`) と example (`examples/`) は、
その上に載せた装置の実例のひとつ。

- 設計と決定事項: [docs/spec.md](docs/spec.md) が single source of truth
- 調べて分かった事実: [docs/research/](docs/research/) (USB: `picoruby-usb-survey.md`、BLE UART / DFU: `picoruby-ble-dfu-survey.md`)
- 機能ごとの設計と実装計画: [docs/superpowers/](docs/superpowers/) の `specs/` と `plans/`
- v1 でやらないと決めたこと: [docs/issues/gamepad.md](docs/issues/gamepad.md)
- 残っている作業: [GitHub issues](https://github.com/bash0C7/R2P2-dev-harness/issues)

## v1 のスコープ

| 項目 | 決定 |
|---|---|
| 対象プラットフォーム | rp2040 (Raspberry Pi Pico 2 W) が主。ESP32 (M5Stack Chain DualKey) は実機を触る rake タスクだけ持つ。USB 周辺機器の gem は rp2040 のみ |
| Mac の役 | **相手役と開発機**。USB 機器になるのは board 側。darwin 版の USB 機器は対象外 |
| 最初の実例 | USB 周辺機器のライブラリ (CDC-MIDI / HID mouse)。**器 (ライブラリの形と rake の共通インタフェース) を先に固める** |
| USB descriptor | **v1 では変えない。** C 固定の制約をそのまま受け入れる |
| 新しい gem の置き場所 | `gems/` 配下。`build_config` から `conf.gem gemdir:` で指す |
| 完了の線引き | **実機検証まで通って green。** ホストのテストだけでは完了としない |
| 無人化 | 焼き込みと検証の無人化は本 repo の**目玉スコープ**。[docs/spec.md](docs/spec.md) の §6 |

darwin 版の USB 機器、ESP32 向けの USB 周辺機器 gem、iPhone / Apple Watch は v1 のスコープ外。

## 守る制約

- **既存の library / repo に直接変更を加えない。** picoruby は `vendor/` へ都度取得する
- **git submodule はハーネスからは直接使わない。** rake で取得し、取得先が submodule を
  必要とするならそこで初期化する
- **既にあるライブラリは活かす。** 置き換えではなく上に載せる

## 使う

```sh
rake setup   # vendor/picoruby を取得する
rake test    # picotest (ホスト) + example の compile。board 無しではここまで
rake -T      # 何ができるか
```

`rake setup` は host build に要る submodule だけを取る。firmware を作るなら
`rake rp2040:setup` で pico-sdk を足してから `rake rp2040:build`。

Pico 2 W 実機 (Mac に USB で接続):

```sh
rake rp2040:build                                  # firmware-patches/ を当てて build し、戻す
rake rp2040:flash                                  # 動作中の board を自分で BOOTSEL へ落として焼く
rake rp2040:run[examples/rp2040/bootsel_click.rb,60]   # 転送して走らせ、ログを取る
rake rp2040:reboot
```

- `rp2040:flash` は `Machine.usb_boot` 入りの firmware が載っていればボタン不要。
  初めて焼くときだけ、BOOTSEL を押したまま USB を挿す
- USB を挿しただけで app を動かすには `/home/app.rb` として置く。起動時に自動実行される
  （`.rb` は mrbc で `.mrb` にして送られ、板には `/home/app.mrb` が置かれる。`HARNESS_SEND_RB=1` でソースのまま送る）:
  `rake rp2040:upload[examples/rp2040/bootsel_click.rb,/home/app.rb]`。
  app が動いている間 shell は黙る。`upload` / `run` / `reboot` は `$>` が返らなければ
  Ctrl-C で app を止めてから shell を使う。`flash` / `reboot` の直後は
  `tools/pico2w/boot_state.rb` が起動状態を読み、app が上がっていればそのまま動かし続ける。
  Ctrl-C で止めた app の `teardown` は走らない ([docs/spec.md](docs/spec.md) §2)
- picoruby の compiler 3つは `Rakefile` の `SUBMODULE_PINS` に固定している。
  upstream の pin では Pico 2 W が起動時に固まる ([docs/spec.md](docs/spec.md) §6)

ESP32 (M5Stack Chain DualKey、Mac に USB で接続)。firmware の build と flash は
`bash0C7/R2P2-ESP32` を `../R2P2-ESP32` に checkout しておくと、そちらの rake に委ねる
(別の場所なら `R2P2_ESP32_REPO=/path/to/R2P2-ESP32`):

```sh
rake esp32:build                          # firmware を build し、QEMU で起動確認まで通す
rake esp32:flash                          # esptool で焼く
rake esp32:qemu_check                     # QEMU で boot loop (Core panic) の有無を判定。焼く前に。IDF の export が前提
rake esp32:run[app.rb,20]                 # .mrb にして転送し、走らせてログを取る
rake esp32:upload[app.rb,/home/app.rb]    # .mrb にして転送だけ。/home/app.mrb は起動時に自動実行される
rake esp32:reboot                         # RTS パルスで reset して shell を待つ
```

- `tools/esp32/` はポートを `ioreg` の製品名で選ぶ。`/dev/cu.usbmodem*` の glob だと
  Pico 2 W と並んだときに取り違える
- `upload` / `run` は `.rb` を mrbc で `.mrb` にして送る (板上の prism が heap を食い `NoMemoryError` になるため)。
  `HARNESS_SEND_RB=1` でソースのまま送る (Pico 2 W も同じ)
- 板の serial / USB を開くタスクと tool は board ごとの lock (`~/.cache/r2p2-device-locks/`) で排他される。
  別 session が使っていると待つ ([docs/spec.md](docs/spec.md) §6)
- ESP32 の罠は [docs/spec.md](docs/spec.md) §9。転送後によく出る問題 (`/home/app.mrb` が残って転送が失敗する等) は [docs/faq.md](docs/faq.md)

FPGA (mruby のバイトコードを直接実行する CPU、issue #4)。`.mrb` を ROM にし、SystemVerilog のコアで走らせ、
Ruby の参照インタプリタと突き合わせる。クラスとメソッド (実行時にメソッド表を引く)、ブロック (`yield` / `proc` / `each` / `map` ...)、配列 (GC 付き)、
`sleep_ms` まで動く (シミュレーション上)。`vendor/picoruby` は要らない。
macOS は brew、Linux は apt-get で Verilator と Icarus Verilog を入れる:

```sh
rake fpga:setup                        # 足りないシミュレータを入れる (brew / apt-get)。最後に doctor を回す
rake fpga:test                         # Ruby の道具のテスト + 全テストベンチ (Verilator と Icarus) + 参照との突き合わせ
rake fpga:emu[fpga/corpus/blink_sleep.mrb] # ボードエミュレーター (既定 125MHz、[src,ms,CE_DIV,MHz] で変更)。LED とボタンの変化を実時間で表示
rake fpga:run[fpga/corpus/counter.mrb] # 1本をシミュレーション上のコアで走らせ、$LED などへの書き込みを表示
rake fpga:fuzz[1000,2]                 # 差分ファズ: ランダムな ROM を参照インタプリタとコアで走らせ、トレースを全行比べる
rake fpga:rom[fpga/corpus/blink.mrb]   # PicoRuby で書いた変換器で ROM イメージと命令一覧を作るだけ
rake fpga:sim[mrb_core_tb]             # テストベンチ1本を Verilator で。波形は build/fpga/mrb_core_tb.fst
rake fpga:build[fpga/corpus/blink.mrb] # PERIDOT-Air 向けに Quartus で合成 (quartus_sh か FPGA_QUARTUS_HOST)。実機では未確認
rake fpga:flash                        # openFPGALoader + USB-Blaster で書く。実機では未確認
```

`fpga:rom` / `fpga:run` / `fpga:build` は変換器を PicoRuby の host VM で走らせるので、`rake setup` と `rake test:host` が要る。波形は `surfer build/fpga/<tb>.fst` で開く。対応命令は [docs/fpga-opcodes.md](docs/fpga-opcodes.md)、
約束事と罠は [docs/spec.md](docs/spec.md) §10。

board 無しで回せるツールのテスト: `rake test:rp2040` (`tools/common` と `tools/pico2w`)、
`rake test:esp32` (`tools/common` と `tools/esp32`)。`rake test` には含まれない。

## 状態

積荷1 (器) まで。

| | |
|---|---|
| `gems/picoruby-usb-peripheral` | setup / tick / teardown の器。ホストのテスト green |
| `gems/picoruby-usb-peripheral-cdc-midi` | CDC-MIDI の結線。ホストのテスト green |
| `gems/picoruby-usb-peripheral-hid-mouse` | HID mouse の結線。ホストのテスト green |
| `gems/picoruby-ble-dev-bridge` | BLE UART の1本の接続で REPL と DFU (app.rb の差し替え) を受けるフレーマ。ホストのテスト green、firmware に入れた cross-build が通る。実機では未実行 |
| `examples/rp2040/midi_scale.rb` | CDC-MIDI の example。`rake test:examples` で compile を確認。実機では未実行 |
| `examples/rp2040/ble_dev_bridge.rb` | `picoruby-ble-dev-bridge` の example。`rake test:examples` で compile を確認。実機では未実行 |
| `examples/rp2040/bootsel_click.rb` | BOOTSEL ボタンを USB マウスの左クリックにし、押している間 LED を点ける。**Pico 2 W 実機で Mac に対してクリックが効き、LED が点いた。`/home/app.rb` として置くと USB を挿しただけで動く** |
| `rake setup` / `refresh` / `test:host` / `clean` | 実装済み |
| `rake rp2040:setup` / `rp2040:build` / `stamp` / `firmware` | 実装済み。**ビルドは通る** (4.6MB の .uf2 が出る) |
| `rake rp2040:flash` | 実装済み。**Pico 2 W 実機で BOOTSEL ボタンなしに通した** (patch 入り firmware が載っていれば) |
| `rake rp2040:upload` / `run` / `reboot` | 実装済み。Pico 2 W 実機で通した。`.rb` は mrbc で `.mrb` にして送る (macOS の `ioreg` と `serialport` gem が要る) |
| `rake rp2040:verify` | 未実装。判定する相手役が無いので落ちる |
| `rake esp32:build` / `flash` / `upload` / `run` / `reboot` | 実装済み。M5Stack Chain DualKey 実機で通した (`R2P2-ESP32` の sibling checkout が要る)。`.rb` → `.mrb` → 転送 → 実行 (現在の既定) も `rake esp32:run` で DualKey 実機に通した |
| `rake esp32:qemu_check` | 実装済み。QEMU で panic の有無をログから判定する。PASS 側 (通常の構成) と FAIL 側 (`PICORB_TASK_STACK_SIZE=1024` で Core 1 が panic) を QEMU で通した |
| `rake test:rp2040` / `test:esp32` | 実装済み。`tools/` の plain-Ruby テスト。board 不要 |
| `tools/pico2w/` | Pico 2 W 実機を触る helper。`picoruby-ble-verify` から。実機で通った |
| `tools/esp32/` | ESP32 実機を触る helper。実機で通った |
| `tools/common/` | `tools/pico2w/` と `tools/esp32/` が共有する PicoModem・端末問い合わせ応答・mrbc での compile・board の排他 lock |
| `firmware-patches/` | build の間だけ vendor/picoruby に当てる patch。`Machine.usb_boot` を足す |

ハーネスの gem は rp2040 の firmware に実際に入っている
(`picogem_init.c` に `usb/peripheral` / `usb/peripheral/cdc_midi` / `usb/peripheral/hid_mouse` が並ぶ)。

実機へは BOOTSEL ボタンなしで焼け、HID mouse の example は USB マウスとして動いた。
**CDC-MIDI の実機検証はまだ通っていない。** 完了の線引きは実機まで
([docs/spec.md](docs/spec.md) §5) なので、積荷1 はまだ「done」ではない。
Mac 側で CDC-MIDI の結果を判定する相手役が無い。
残っている作業は [GitHub issues](https://github.com/bash0C7/R2P2-dev-harness/issues) にある。
