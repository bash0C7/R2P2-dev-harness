# 調査: picoruby の USB 周りと既存ハーネス

2026-09-13 時点。`picoruby/picoruby` の default branch を shallow clone して読んだ結果と、
`bash0C7/R2P2-darwin` / `picoruby/R2P2` / `bash0C7/picoruby-ble-verify` の観察。
仕様ではなく事実の記録。

## 既存 gem は3つ

| gem | 中身 | descriptor 変更 |
|---|---|---|
| `picoruby-usb-hid` | keyboard / mouse / consumer。`USB::HID.send_key` など | 要 (C 固定) |
| `picoruby-usb-cdc-midi` | MIDI over CDC。`USB::CDC::MIDIOutput#putevent` | **不要** |
| `picoruby-ble-hid` | `BLE::HID < BLE`。report map は Ruby の文字列定数 | 不要 (ただし制限あり) |

### `picoruby-usb-cdc-midi` の形

- `USB::CDC::MIDIOutput#initialize(write_timeout_ms:)` / `#connected?` /
  `#putevent(command, *values)` / `#handle` / `#handle_midi`
- private `#write_bytes` が `USB::CDC._midi_write` を回し、詰まったら
  `Machine.tud_task` + `sleep_ms 1` で待つ。deadline は `write_timeout_ms`
- 依存は `picoruby-machine` と `picoruby-midibase`。`picoruby-mrubyc` と conflict
- example (`example/scale.rb`) は `until output.connected?` で待ってから putevent する。
  **接続待ちもループも tud_task もアプリ側に書かせている** — ここが器の余地
- test (`test/midi_output_test.rb`) は `write_bytes` を subclass で差し替えて
  ホストで回している。**C に触らずテストする前例がここにある**

## USB descriptor は C 固定

`mrbgems/picoruby-r2p2/ports/rp2040/usb_descriptors.c`:

- enum は `ITF_NUM_CDC_0 / _DATA` ×3 → `ITF_NUM_HID_KEYBOARD` / `_MOUSE` / `_CONSUMER` →
  `ITF_NUM_TOTAL`。コンパイル時に決まる
- `CONFIG_TOTAL_LEN` は `CFG_TUD_CDC` と `CFG_TUD_HID` から算出
- 3つの HID report descriptor は `TUD_HID_REPORT_DESC_KEYBOARD()` /
  `_MOUSE()` / `_CONSUMER()` をそのまま使うので **report ID を持たない**
- `tusb_config.h`: `CFG_TUD_CDC 3` / `CFG_TUD_HID 3` / `CFG_TUD_MIDI 0` / `CFG_TUD_VENDOR 0`

含意は [../issues/gamepad.md](../issues/gamepad.md)。

## BLE-HID の report map は Ruby にあるが、それだけでは足りない

`mrbgems/picoruby-ble-hid/mrblib/ble_hid.rb`:

- `KEYBOARD_REPORT_MAP` / `CONSUMER_REPORT_MAP` (Report ID 2) /
  `MOUSE_REPORT_MAP` (Report ID 3) が文字列定数。`_build_report_map` が
  `@consumer_enabled` / `@mouse_enabled` を見て連結する
- `_build_report_map` は普通のインスタンスメソッドなので subclass で override できる
- **ただし** `initialize` が GATT の characteristic を3本直書きし、
  `@keyboard_input_handle` / `@consumer_input_handle` / `@mouse_input_handle` を
  そこで拾う。`_flush_reports` もその3本だけを見る。
  4本目を subclass から足す隙が無い

## テストの仕組み

`tasks/picoruby/test.rake`:

- `rake test:gems:picoruby[<gem>]` が gem のテストを回す。
  temp build_config を作って `build/host/bin/picoruby` を建て、picotest runner にかける
- **`collect_gems` は `MRUBY_ROOT/mrbgems/picoruby-*` と `mruby-*` しか glob しない。**
  `conf.gem gemdir:` で外から差した gem は build には乗るが、**テストには拾われない**
- `picoruby-picotest` は `stub` / `mock` / `stub_any_instance_of` / `mock_any_instance_of` を持つ

`conf.gem gemdir:` の前例は `build_config/picoruby-wasm.rb` (mruby-binding / mruby-math を
submodule の中から直接指している)。

## 既存ハーネスの形

### `bash0C7/R2P2-darwin`

本 repo が一番近いことをしている先行例。

- `Rakefile` が `PICORUBY_REPO` / `PICORUBY_REF` env で `vendor/picoruby` を取得
  (`rake setup` / `rake refresh`)。`vendor/picoruby` は生成物で commit しない
- `stage_libmruby` が `build/<name>/.r2p2-build-stamp` に
  「picoruby の SHA + build_config の digest」を書く。一致しなければ dir ごと捨てる。
  **mruby の compile rule は `.c` の mtime しか見ないので、取得し直した tree の方が
  既存 `.o` より古いと何も再 compile されず、成功したと言いながら前の archive を stage する**
- example ごとに `lib` → `gen` → `build` → `run` → `all` の namespace が揃っている。
  device 系は `device:` の下に同じ名前で並ぶ
- 完了の線引きは `rake regress:unit` (host, CI) → device link → 実機の挙動。
  「実機の挙動は実機で実証するまで『動いた』と書かない」
- **gem の port は fork `bash0C7/picoruby` の `port-darwin` branch が持つ。**
  本 repo 側には build_config / bridge / example / example 専用 gem だけを置く

### `picoruby/R2P2`

`vm × board × mode` の namespace (`r2p2:picoruby:pico2_w:prod` など) で
firmware を焼くところまで。

### `bash0C7/picoruby-ble-verify` (private)

実機検証の資産。`pico2w/` に picomodem / pmput / rsh / runapp / stages、
`esp32/` に同等のもの。SKILL.md に踏まないと分からない知見が入っている
(詳細は [../spec.md](../spec.md) §6 に転記した)。

人間にしか頼めない操作は3つだけ:
BOOTSEL 書き込み / ハング復旧の USB 抜き差し / Mac の Bluetooth 許可ダイアログ。

**現行 firmware には reset interface が無く `picotool reboot` が効かない。
1200-baud touch も効かない。** これが無人化の最大の障害。

## 関連する外部の記録

- Obsidian Vault:
  `02_dev_docs/picoruby-ble-esp32-port/notes/2026-09-11-picoruby-4fe6e254-r2p2-esp32-breakage.md`
