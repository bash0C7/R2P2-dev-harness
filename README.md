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
| 対象プラットフォーム | rp2040 (Raspberry Pi Pico 2 W) + darwin (Mac が相手役) |
| 第1積荷 | USB CDC-MIDI。**器 (ライブラリの形と rake の共通インタフェース) を先に固める** |
| USB descriptor | **v1 では変えない。** C 固定の制約をそのまま受け入れる |
| 新しい gem の置き場所 | `gems/` 配下。`build_config` から `conf.gem gemdir:` で指す |
| 完了の線引き | **実機検証まで通って green。** ホストのテストだけでは完了としない |
| 無人化 | 焼き込みと検証の無人化は本 repo の**目玉スコープ**。[docs/spec.md](docs/spec.md) の §6 |

ESP32 は2番目の積荷。iPhone / Apple Watch は v1 のスコープ外。

## 守る制約

- **既存の library / repo に直接変更を加えない。** picoruby は `vendor/` へ都度取得する
- **git submodule はハーネスからは直接使わない。** rake で取得し、取得先が submodule を
  必要とするならそこで初期化する
- **既にあるライブラリは活かす。** 置き換えではなく上に載せる

## 状態

設計中。実装は未着手。
