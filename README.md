# R2P2-dev-harness

PicoRuby を **USB 周辺機器**にするためのライブラリと、その開発ハーネス。

やりたいのは「PicoRuby で USB 機器を作る」こと。そのためのライブラリを用意する repo であって、
製品ではない。いま知見も rake タスクも R2P2-darwin / R2P2-ESP32 / picoruby/picoruby に
散らばっているので、1箇所に集める。

- 設計と決定事項: [docs/spec.md](docs/spec.md) が single source of truth
- 調べて分かった事実: [docs/research/picoruby-usb-survey.md](docs/research/picoruby-usb-survey.md)
- v1 でやらないと決めたこと: [docs/issues/gamepad.md](docs/issues/gamepad.md)
- Mac 側に渡す作業: [docs/handoff-to-mac.md](docs/handoff-to-mac.md)

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

## 状態

積荷1 (器) まで。

| | |
|---|---|
| `gems/picoruby-usb-peripheral` | setup / tick / teardown の器。ホストのテスト 21 件 green |
| `gems/picoruby-usb-peripheral-cdc-midi` | CDC-MIDI の結線。ホストのテスト 23 件 green |
| `examples/rp2040/midi_scale.rb` | example 第1号。`rake test:examples` で compile を確認 |
| `rake setup` / `refresh` / `test:host` / `clean` | 実装済み |
| `rake rp2040:setup` / `rp2040:build` / `stamp` / `firmware` | 実装済み。**ビルドは通る** (4.6MB の .uf2 が出る) |
| `rake rp2040:flash` / `upload` / `run` / `reboot` | 実装済み。flash は BOOTSEL ボタン不要 (patch 入り firmware が載っていれば)。**本 repo から実機で未検証** (macOS の `ioreg` と `serialport` gem が要る) |
| `rake rp2040:verify` | 未実装。判定する相手役が無いので落ちる |
| `tools/pico2w/` | 実機を触る helper。`picoruby-ble-verify` から。本 repo から実機で未検証 |
| `firmware-patches/` | build の間だけ vendor/picoruby に当てる patch。`Machine.usb_boot` を足す |

ハーネスの gem は rp2040 の firmware に実際に入っている
(`picogem_init.c` に `usb/peripheral` と `usb/peripheral/cdc_midi` が並ぶ)。

**それでも実機検証は1つも通っていない。** 完了の線引きは実機まで
([docs/spec.md](docs/spec.md) §5) なので、積荷1 はまだ「done」ではない。
焼く・走らせるところまで道具は揃ったが、Mac 側で結果を判定する相手役が無い。
実機側の作業は [docs/handoff-to-mac.md](docs/handoff-to-mac.md)。
