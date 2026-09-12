# R2P2-dev-harness HANDOFF

2026-09-13 作成。ここまでは brainstorming の途中まで。設計はまだ確定していない。
続きは Claude Code on web で行う。

## 何を作るのか

複数プラットフォーム向け PicoRuby 開発のハーネス。いま知見も rake タスクも repo ごとに
散らばっており、R2P2-darwin / R2P2-ESP32 / picoruby/picoruby を都度持ってくるのが重い。
それを1箇所に集める。repo 名のとおり「開発ハーネス」であって、製品ではない。

## 決まっていること

- **v1 の対象は rp2040 + darwin の2つ。** 実機は Pico 2 W、相手役とテストは Mac。
  ESP32 は2番目の積荷で入れる。iPhone と Apple Watch は v1 のスコープ外
  (それらの上で PicoRuby が何をするのかが未定義のため)
- **既存の library / repo には直接変更を加えない。** 都度 GitHub から取得する
- **git submodule はハーネスからは直接使わない。** rake で取得し、取得した先が
  submodule を必要とするならそこで初期化する
- テストが回ること
- 最初の積荷は USB 周辺機器化。PicoRuby を Mac / PC の USB デバイスにする
- **既にあるライブラリは活かす。** 置き換えではなく上に載せる

## ライブラリの形 (指定済み)

初期化・メインループ・片付け のそれぞれにメソッドがあり、具体の処理はブロックで渡す。
USB 制御としての共通的なことはライブラリ内にカプセル化する。
片付けが要るかどうかは未検討。

example 第1号はゲームコントローラー。よくある Xbox コントローラー偽装のもので、
まずは Raspberry Pi Pico 2 W の基板上のボタン1つを使う。

## 調査で分かった事実

picoruby の木 (`~/dev/src/github.com/bash0C7/picoruby-ble-esp32-port`、
branch `picoruby-ble-esp32-port`) を読んだ結果。

### 既存 gem は3つある

| gem | 中身 | descriptor 変更 |
|---|---|---|
| `picoruby-usb-hid` | keyboard / mouse / consumer。`USB::HID.send_key` など | 要 (C 固定) |
| `picoruby-usb-cdc-midi` | MIDI over CDC。`USB::CDC::MIDIOutput#putevent` | **不要** |
| `picoruby-ble-hid` | `BLE::HID < BLE`。report map は Ruby の文字列定数 | **不要** |

### USB descriptor は C で固定されている

`mrbgems/picoruby-r2p2/ports/rp2040/usb_descriptors.c`:

- インタフェースは CDC×3 + HID×3 (keyboard / mouse / consumer)、`ITF_NUM_TOTAL` は
  コンパイル時に決まる
- 3つの HID はいずれも report ID を持たない (`TUD_HID_REPORT_DESC_KEYBOARD()` 等を
  そのまま使用) ので、**ゲームパッドを既存インタフェースに相乗りさせられない**
- `tusb_config.h`: `CFG_TUD_CDC 3` / `CFG_TUD_HID 3` / `CFG_TUD_MIDI 0` /
  `CFG_TUD_VENDOR 0`

### Xbox 偽装には2通りある

- **XInput (本物)**: ベンダクラス。`CFG_TUD_VENDOR` と専用の VID/PID が要る。現在 0
- **標準 HID ゲームパッド**: TinyUSB に `TUD_HID_REPORT_DESC_GAMEPAD` がある。
  macOS はそのまま認識する。難易度が段違いに低い

### BLE HID の report map は Ruby 側にある

`picoruby-ble-hid/mrblib/*.rb` に `KEYBOARD_REPORT_MAP` / `MOUSE_REPORT_MAP` /
`CONSUMER_REPORT_MAP` が文字列定数として並び、`_build_report_map` が組み立てる。
**ゲームパッドの report map を足すのに C 変更は要らない。**
(`_build_report_map` を subclass で上書きできるかは未確認)

## ここから出る含意

**「既存 repo に直接変更しない」という制約は、USB HID ゲームパッドと正面から衝突する。**
descriptor に4つ目のインタフェースを足すには picoruby 本体の C を変えるしかない。
取りうる道は3つあり、未決:

1. ビルド時にハーネスが overlay / patch を当てる (repo そのものは書き換えない)
2. upstream へ PR を出して取り込まれるのを待つ
3. USB は諦めて BLE HID ゲームパッドで先に成立させる

一方 **CDC-MIDI と BLE-HID のクイック送信は、既存 repo を一切触らずに到達できる。**

## 積荷の順序 (案、未承認)

1. CDC-MIDI のクイック送信 — descriptor 変更不要
2. BLE-HID のクイック送信 (ゲームパッド report map を含む) — C 変更不要
3. USB HID ゲームパッド — 上の道の選択が先

## 未決の設計論点

web で続ける際に決めるべきこと。

- **新しいコードの置き場所と取り込ませ方。** ハーネス内に gem を置き、build_config から
  `conf.gem gemdir: <harness>/gems/...` で指す案がある (mruby の build は gemdir 指定を
  受け付ける。既存 build_config に前例あり)。gem を独立 repo にする案もある
- **descriptor 変更の扱い。** 上の3つの道のどれか
- **「テストが回る」の意味。** ホスト側の picotest か、実機か、両方か。
  ホストで回せる範囲がどこまでかを決める必要がある
- **片付け (cleanup) が本当に要るか。** USB デバイスとして必要な終了処理があるか未調査
- **rake タスクの共通インタフェース。** 何を揃えれば「つど作らなくてよい」状態になるか

## 環境

- `~/dev/src/github.com/bash0C7/R2P2-dev-harness` は **空** (`.git` のみ)。
  **remote も未設定。** Claude Code on web で使うには GitHub に repo を作って
  push する必要がある
- 実機 (Pico 2 W) の焼き方・転送・ログ取りの手順は、picoruby の worktree 内にある
  ローカル skill `.claude/skills/pico2w-ble-verify/` にまとまっている。
  無人化の仕組みと firmware patch は private repo `bash0C7/picoruby-ble-verify`
- 関連する調査記録: Obsidian Vault の
  `02_dev_docs/picoruby-ble-esp32-port/notes/2026-09-11-picoruby-4fe6e254-r2p2-esp32-breakage.md`

## 進め方

superpowers の brainstorming で architectural 経路に入ったところ。
残りは「方式を2〜3案出して比較 → 節ごとに設計を提示して承認 → spec 文書 → writing-plans」。
上の未決論点が質問の材料になる。
