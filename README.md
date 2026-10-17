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
`rake esp32:setup` が `vendor/R2P2-ESP32` に clone する `bash0C7/R2P2-ESP32` の rake に委ねる
(別の場所なら `R2P2_ESP32_REPO=/path/to/R2P2-ESP32`)。ESP-IDF は Mac に入れず、
build と QEMU は下の「Apple Container で回す」のとおり container の中で回す:

```sh
rake esp32:setup                              # vendor/R2P2-ESP32 を clone する (picoruby submodule は取らない)
rake "container:rake[esp32:build]"            # firmware を build し、QEMU で起動確認まで通す (container の中で)
rake "container:rake[esp32:qemu_check]"       # QEMU で boot loop (Core panic) の有無を判定。焼く前に
rake esp32:flash                              # esptool で焼く (ここから下はホストで)
rake esp32:run[app.rb,20]                     # .mrb にして転送し、走らせてログを取る
rake esp32:upload[app.rb,/home/app.rb]        # .mrb にして転送だけ。/home/app.mrb は起動時に自動実行される
rake esp32:reboot                             # RTS パルスで reset して shell を待つ
```

- `tools/esp32/` はポートを `ioreg` の製品名で選ぶ。`/dev/cu.usbmodem*` の glob だと
  Pico 2 W と並んだときに取り違える
- `upload` / `run` は `.rb` を mrbc で `.mrb` にして送る (板上の prism が heap を食い `NoMemoryError` になるため)。
  `HARNESS_SEND_RB=1` でソースのまま送る (Pico 2 W も同じ)
- 板の serial / USB を開くタスクと tool は board ごとの lock (`~/.cache/r2p2-device-locks/`) で排他される。
  別 session が使っていると待つ ([docs/spec.md](docs/spec.md) §6)
- ESP32 の罠は [docs/spec.md](docs/spec.md) §9。転送後によく出る問題 (`/home/app.mrb` が残って転送が失敗する等) は [docs/faq.md](docs/faq.md)

board 無しで回せるツールのテスト: `rake test:rp2040` (`tools/common` と `tools/pico2w`)、
`rake test:esp32` (`tools/common` と `tools/esp32`)、`rake test:container` (`tools/container`)。
`rake test` には含まれない。

### Apple Container で回す

Mac に ESP-IDF も arm-none-eabi も入れない。build と QEMU は Apple Container (`container` CLI) の中で回す
([docs/spec.md](docs/spec.md) §9)。base image `espressif/idf:v5.5.4` から常駐コンテナ `r2p2-dev-harness` を 1 つ作り、
足りないパッケージ (Ruby の開発ヘッダ、arm-none-eabi など) は `container/provision.sh` で一度だけ入れる。
各タスクは `container exec` で走る。派生 image は作らない (展開済み snapshot が image ごとにもう 1 つ、9 GB 増えるため)。

初回だけ:

```sh
container system start
rake container:image        # base image を curl で取得して load (入れると約 14 GB)。空きが CONTAINER_MIN_FREE_GB (既定 20) 未満なら止まる
rake esp32:setup            # vendor/R2P2-ESP32 を clone する
```

PR の picoruby を ESP32 の QEMU で試す (例は picoruby PR #427 の branch):

```sh
rake "picoruby:worktree[picoruby-ble-esp32-port]"   # ghq の picoruby clone から vendor/worktrees/picoruby/<branch> に worktree
export ESP32_PICORUBY=vendor/worktrees/picoruby/picoruby-ble-esp32-port   # R2P2-ESP32 の picoruby submodule の位置に重ねる
EVQ_VM=mruby  rake "container:rake[esp32:evq_green]" # harness の rake を container の中で (初回は container:up が走る)
EVQ_VM=mrubyc rake "container:rake[esp32:evq_green]"
CMD='rake test:gems:picoruby' DIR=$ESP32_PICORUBY rake container:exec        # upstream のテストなど、任意のコマンド
CMD='rake r2p2:picoruby:pico2_w:prod' DIR=$ESP32_PICORUBY rake container:exec # Pico 2 W 向けの .uf2 も同じ tree から
```

その他:

```sh
rake container:shell
rake "container:ruby[4.0.1]"    # base の Ruby は 3.2。upstream の CI と同じ Ruby を tmp/container/ruby/ に build
CONTAINER_RUBY=4.0.1 CMD='BUNDLE_FROZEN=true bundle install && rake test:gems:steep' DIR=$ESP32_PICORUBY rake container:exec
rake container:provision        # container/provision.sh を書き換えたら、今のコンテナにかけ直す
rake container:stop             # 使い終わったら止めて memory を返す。次の container:* が起こす
rake container:down             # コンテナを消す (image と tmp/container は残る)
rake "picoruby:worktree_remove[picoruby-ble-esp32-port]"   # worktree を外す (変更が残っていれば止まる)
```

- mount はコンテナを作るときにしか決められない。`ESP32_PICORUBY` / `CONTAINER_CPUS` / `CONTAINER_MEMORY` を
  今と違う値で明示すると、次の `container:*` がコンテナを作り直す (中身は全部 mount 側にあるので、失うのは provision だけ)。
  何も明示しなければ今あるコンテナをそのまま使う
- mount はホストと同じ絶対パス。worktree の `.git` が ghq clone (`PICORUBY_CLONE`、既定 `~/ghq/github.com/bash0C7/picoruby`) を指すので、clone も mount する。
  container から見えるのは harness root、その clone、R2P2-ESP32 だけ。container で走らせる script は harness の `tmp/` に置く
- container の HOME と cache は `tmp/container/` 配下。ホストの環境変数は `SDKCONFIG_DEFAULTS` や `EVQ_*` など決めたものだけ渡る (`tools/container/run_args.rb`)
- 長い build や QEMU は数分かかる。log を `tmp/` に書いて background で回す
- 実機を触るタスク (`flash` / `upload` / `run` / `reboot`) はホストのまま。container から serial は見えない
- `container image pull` を使わない理由など、container の罠は [docs/spec.md](docs/spec.md) §9

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
