# ESP32を2番目の対象にする — 設計

元issue: [#12](https://github.com/bash0C7/R2P2-dev-harness/issues/12)

## 目的

rp2040（Pico 2 W）と同じrakeの共通インタフェース（docs/spec.md §4）で、ESP32の装置もこのrepoから焼いて・転送して・走らせて・再起動できるようにする。ESP32で踏んだ罠をこのrepoに集約する。

## 決定事項（brainstormingで詰めた4つの問い）

| 問い | 決定 |
|---|---|
| 対象ボード | M5Stack Chain DualKey（ESP32-S3、PSRAM無し）。`bash0C7/R2P2-ESP32` branch `r2p2-esp32-btstack-integration`で、picoruby upstream/master 77927f45 + `MRC_PRISM_ARENA_BLOCK=2048`により実機起動完走まで確認済み（issue #12コメント参照） |
| 書き込み方式 | esptoolのみ。`R2P2-ESP32`側でビルド済みの成果物を焼く。ESP-IDFのフルインストールはこのharnessの責務にしない |
| QEMU検証 | 入れる。`R2P2-ESP32`が自身のCIで持っているQEMU起動確認を、実機の前段として流用する |
| 取り込み元 | build/flashは`R2P2-ESP32`のRakeタスクをそのまま呼ぶ。reset（RTSパルス）とpicomodemの知見はstackchan-picorubyから移植し、このharnessだけで完結させる（依存を残さない）。stackchan-picorubyからの引き剥がしは対象外 |

## アーキテクチャ

### rakeタスク（`rakelib/esp32.rake`、新設）

rp2040.rakeと同じ共通インタフェース（`esp32:build` / `flash` / `upload` / `run` / `reboot`）を持つ。

- **`esp32:build`**: `R2P2-ESP32`のsibling checkout（デフォルト `../R2P2-ESP32`、`R2P2_ESP32_REPO`環境変数で上書き可 — `PICORUBY_REPO`/`PICORUBY_REF`と同じ流儀）へ`Dir.chdir`し、そちらの`rake build`（Chain DualKey向けVM設定）を呼ぶ。続けて`rake setup_qemu && rake qemu`でQEMU起動確認を通す
- **`esp32:flash`**: 同じsibling checkoutの`rake flash`（esptool、ESP-IDF不要）を呼ぶ
- **`esp32:upload`** / **`esp32:run`**: `tools/esp32/`に置く、このharness自前のpicomodemクライアントで`/home/app.rb`(or `.mrb`)を転送・実行する。プロトコル層（STX/frame/CRC16、terminal query応答）は`tools/pico2w/picomodem.rb`と同じpicoruby-picomodemプロトコルであり、共有できるか（`tools/common/`への切り出し）は実装時に判断する。無理に共通化せず、まず`tools/esp32/`単独版で動かしてよい
- **`esp32:reboot`**: `tools/esp32/reset.rb`で、stackchan-picorubyの`pulse RTS to reset CoreS3`（Rakefile:399、Python/pyserial実装）と同じ手順を**Rubyの`serialport` gem**（`tools/pico2w`が既に依存に持つもの）で実装する。Pythonは使わない（このrepoの規律）

### データフロー

```
esp32:build  -> R2P2-ESP32/rake build (mruby VM, Chain DualKey) -> R2P2-ESP32/rake setup_qemu && qemu (起動確認)
esp32:flash  -> R2P2-ESP32/rake flash (esptool)
esp32:upload -> tools/esp32/ picomodemクライアント -> シリアル経由で /home/app.rb 転送
esp32:run    -> 同クライアントでアプリ実行
esp32:reboot -> tools/esp32/reset.rb (RTSパルス, serialport gem)
```

### エラー処理

rp2040.rakeが持つ`tools/pico2w/tmo.rb`（時間区切りのserial open）・`shell_ok.rb`（`$>`プロンプトでの生存判定、bytesが返るだけでは生存とみなさない）と同じ考え方をESP32側にも適用する。ESP32固有の罠（issue #12に既出）:

- シリアルポートを開くだけでリセットされる（Pico 2 Wと逆の前提）
- ポートを`/dev/cu.usbmodem*`のglobで選ばない（ESP32が先に並ぶ）
- PSRAM無しで heap 約180KB。`MRC_PRISM_ARENA_BLOCK=2048`が無いと`NoMemoryError` → reboot loop（issue #1・#12で確認済み）

これらはdocs/spec.mdの新しい節（§6のrp2040罠と並ぶESP32罠の節）にまとめる。

### テスト

- ホスト層: `tools/esp32/`に移植したreset・picomodemロジックのユニットテスト（`rake test:host`、fake serialでの検証。`tools/pico2w`のテストと同じパターン）
- 実機層: Chain DualKeyで`build` / `flash` / `upload` / `run` / `reboot`が通ることを確認

## スコープ外

- `gems/`のUSB周辺機器ライブラリのESP32対応（issue #12の「アプローチ案」で後回しと決めた通り）
- stackchan-picorubyからのreset/picomodem重複コードの削除（引き剥がし）
- ESP-IDFのフルインストール手順の整備

## 完了条件（元issueから変更なし）

- Chain DualKeyで`rake esp32:build` / `flash` / `upload` / `run` / `reboot`が通る
- docs/spec.mdにESP32の罠が1節としてまとまっている
