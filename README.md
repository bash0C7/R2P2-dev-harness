# R2P2-dev-harness

PicoRuby を **USB 周辺機器**にするためのライブラリと、その開発ハーネス。

やりたいのは「PicoRuby で USB 機器を作る」こと。そのためのライブラリを用意する repo であって、
製品ではない。いま知見も rake タスクも R2P2-darwin / R2P2-ESP32 / picoruby/picoruby に
散らばっているので、1箇所に集める。

- 設計と決定事項: [docs/spec.md](docs/spec.md) が single source of truth
- 調べて分かった事実: [docs/research/picoruby-usb-survey.md](docs/research/picoruby-usb-survey.md)
- v1 でやらないと決めたこと: [docs/issues/gamepad.md](docs/issues/gamepad.md)
- 残っている作業: [GitHub issues](https://github.com/bash0C7/R2P2-dev-harness/issues)

## v1 のスコープ

| 項目 | 決定 |
|---|---|
| 対象プラットフォーム | rp2040 (Raspberry Pi Pico 2 W) のみ |
| Mac の役 | **相手役と開発機**。USB 機器になるのは board 側。darwin 版の USB 機器は対象外 |
| 第1積荷 | USB CDC-MIDI。**器 (ライブラリの形と rake の共通インタフェース) を先に固める** |
| USB descriptor | **v1 では変えない。** C 固定の制約をそのまま受け入れる |
| 新しい gem の置き場所 | `gems/` 配下。`build_config` から `conf.gem gemdir:` で指す |
| 完了の線引き | **実機検証まで通って green。** ホストのテストだけでは完了としない |
| 無人化 | 焼き込みと検証の無人化は本 repo の**目玉スコープ**。[docs/spec.md](docs/spec.md) の §6 |

ESP32 は2番目の積荷。darwin 版の USB 機器、iPhone / Apple Watch は v1 のスコープ外。

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
- picoruby の compiler 3つは `Rakefile` の `SUBMODULE_PINS` に固定している。
  upstream の pin では Pico 2 W が起動時に固まる ([docs/spec.md](docs/spec.md) §6)

## 状態

積荷1 (器) まで。

| | |
|---|---|
| `gems/picoruby-usb-peripheral` | setup / tick / teardown の器。ホストのテスト green |
| `gems/picoruby-usb-peripheral-cdc-midi` | CDC-MIDI の結線。ホストのテスト green |
| `gems/picoruby-usb-peripheral-hid-mouse` | HID mouse の結線。ホストのテスト green |
| `examples/rp2040/midi_scale.rb` | CDC-MIDI の example。`rake test:examples` で compile を確認。実機では未実行 |
| `examples/rp2040/bootsel_click.rb` | BOOTSEL ボタンを USB マウスの左クリックにする。**Pico 2 W 実機で Mac に対してクリックが効いた** |
| `rake setup` / `refresh` / `test:host` / `clean` | 実装済み |
| `rake rp2040:setup` / `rp2040:build` / `stamp` / `firmware` | 実装済み。**ビルドは通る** (4.6MB の .uf2 が出る) |
| `rake rp2040:flash` | 実装済み。**Pico 2 W 実機で BOOTSEL ボタンなしに通した** (patch 入り firmware が載っていれば) |
| `rake rp2040:upload` / `run` / `reboot` | 実装済み。Pico 2 W 実機で通した (macOS の `ioreg` と `serialport` gem が要る) |
| `rake rp2040:verify` | 未実装。判定する相手役が無いので落ちる |
| `tools/pico2w/` | 実機を触る helper。`picoruby-ble-verify` から。実機で通った |
| `firmware-patches/` | build の間だけ vendor/picoruby に当てる patch。`Machine.usb_boot` を足す |

ハーネスの gem は rp2040 の firmware に実際に入っている
(`picogem_init.c` に `usb/peripheral` / `usb/peripheral/cdc_midi` / `usb/peripheral/hid_mouse` が並ぶ)。

実機へは BOOTSEL ボタンなしで焼け、HID mouse の example は USB マウスとして動いた。
**CDC-MIDI の実機検証はまだ通っていない。** 完了の線引きは実機まで
([docs/spec.md](docs/spec.md) §5) なので、積荷1 はまだ「done」ではない。
Mac 側で CDC-MIDI の結果を判定する相手役が無い。
残っている作業は [GitHub issues](https://github.com/bash0C7/R2P2-dev-harness/issues) にある。
