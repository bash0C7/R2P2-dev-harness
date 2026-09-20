# 調査: picoruby の BLE / DFU 周り

2026-09-20 時点。`picoruby/picoruby` の default branch を shallow clone (`65b7ae6`, 2026-09-17)
して読んだ結果。iOS 開発ハーネスアプリの検討([../superpowers/specs/2026-09-20-ios-dev-harness-app-design.md](../superpowers/specs/2026-09-20-ios-dev-harness-app-design.md))
の前提調査。`picoruby-usb-survey.md` と同じく、仕様ではなく事実の記録。

## 結論から

iOS からは USB CDC シリアルを開けない(MFi 必須)ので、稼働中の R2P2 shell との対話は
BLE に転送経路を作る必要がある、という前提でブレストしていたが、**その転送経路は
すでに upstream にある。新規の C 実装は要らない。**

- `picoruby-ble` + `picoruby-ble-uart` (Nordic UART Service) は
  **`build_config/r2p2-picoruby-pico2_w.rb` にすでに `conf.gem core:` で入っている**
  (このharnessが焼いている実機と同じ build_config)。BLE UART は今の Pico 2 W 実機に
  焼くだけで有効
- `picoruby-dfu` (A/B スロットの OTA アップデータ) も upstream にあるが、
  pico2_w の build_config には**入っていない**。1行の `conf.gem core: 'picoruby-dfu'`
  を足せば使える

## `picoruby-ble` — BLE central/peripheral/GATT の土台

`mrbgems/picoruby-ble/`:

- `BLE` クラスが central / peripheral / observer / broadcaster の4 role を持つ
- rp2040 向け C port が実在: `ports/rp2040/ble.c` / `ble_peripheral.c` / `ble_central.c`。
  BTstack + CYW43 を使う (`include/btstack_config.h`)。**このharnessが対象にしている
  Pico 2 W (RP2350 + CYW43439) と同じチップ**
- `BLE::GattDatabase` で GATT service/characteristic/descriptor を Ruby から組み立てられる
  (`add_service` / `add_characteristic` / `add_descriptor`)。§前回のブレストで「4本目の
  characteristic を足す隙が無い」と書いた `picoruby-ble-hid` の制約は `BLE::HID` という
  **1つの subclass の設計**の話であって、`BLE` 自体は任意の GATT を組める
- `start(timeout_ms, &block)` が event loop。`packet_callback` / `heartbeat_callback` を
  override する形。`Machine.tud_task` 相当の「アプリが放置しても服務される」保証は
  無く、`start` のループ自身が BTstack のイベントを pop して回す

## `picoruby-ble-uart` — Nordic UART Service、pure Ruby

`mrbgems/picoruby-ble-uart/mrblib/ble_uart.rb`:

- `BLE::UART < BLE`。標準の Nordic UART Service UUID (`6e400001-...`) を使う。
  central 役・peripheral 役の両方を1クラスで持つ
- IO 的な API: `write` / `puts` / `read_nonblock` / `gets_nonblock` / `available?` /
  `connected?`。TX/RX それぞれ 1024 バイトの上限バッファ(古いバイトから捨てる)
- peripheral 役は `on_connect` / `on_disconnect` フックと、ATT MTU に応じた
  `notify_chunk_size` の自動調整を持つ
- 依存は `picoruby-ble` のみ。**C の変更は無し** — `picoruby-ble` の rp2040 port が
  そのまま使われる
- `example/ble_irb.rb` が **BLE 越しの REPL サーバの実例そのもの**:
  `Sandbox.new` で1行ずつ `compile` → `execute` → 結果を `uart.puts` で notify。
  「実機なしで試す Playground」ではなく「実機に BLE で直接 Ruby を打ち込む REPL」だが、
  同じ transport (`BLE::UART`) の上に両方を載せられる
- `example/ble_uart_central.rb` もある。**2枚の Pico があれば、iOS 側が無くても
  pico-to-pico で BLE UART の往復を実機検証できる**(iOS の CoreBluetooth 実装より先に
  実機の一次ループを固められる)

## `picoruby-dfu` — 転送済みの OTA アップデータ、transport-agnostic

`mrbgems/picoruby-dfu/`:

- `DFU::Updater#receive(io)` が `#read` を持つ任意の IO で動く。README に明記:
  「Transport-agnostic: Single receive(io) API works with any IO-like object
  (TCP, BLE, etc.)」。`BLE::UART` のインスタンスをそのまま渡せる想定で作られている
  (`ble_uart.rb` の `BufferIO` コメントが `DFU::Updater#receive` 互換だと明言)
- 19 バイトの固定ヘッダ (`magic/version/type/size/crc32/sig_len`) + 任意署名 + 本体、
  という単純なバイナリプロトコル。`type` は `"RUBY"` (`.rb` ソース) か `"RITE"`
  (`.mrb` バイトコード)
- **A/B スロット管理と自動ロールバックを標準搭載**: `/home/app_a.{mrb,rb}` /
  `app_b.{mrb,rb}` を切り替え、`meta.yml` で状態管理。起動失敗が
  `max_boot_attempts` を超えると自動で前スロットに戻る。停電耐性のため
  `meta_tmp.yml` パターンで書く
- CRC32 検証は標準、ECDSA (secp256r1) 署名検証はオプション (`picoruby-mbedtls` 要)
- **`path:` オプションで A/B スロットを経由せず直接そのパスへ書ける**
  (`DFU::Updater.new(path: "/home/app.rb")`)。開発イテレーションで毎回スロット
  切り替えせず `/home/app.rb` を直接上書きしたい用途に向く
- ただし **これは Ruby アプリ層の更新であって、R2P2 の C ランタイム(firmware 本体、
  `vendor/picoruby` がビルドする `.uf2`)の更新ではない。** ファーム本体の書き換えは
  従来通り BOOTSEL + USB Mass Storage 経由のまま
- pico2_w の build_config には**まだ入っていない**(`grep -rl picoruby-dfu build_config/`
  はヒット無し)。追加するにはこのharnessの shim overlay (docs/spec.md §3) に
  `conf.gem core: 'picoruby-dfu'` を足すだけで済むはず(gemdir では無く upstream の
  core gem なので、`build_config/r2p2-picoruby-pico2_w.rb` への1行追記に相当)

## 依存関係を実際に確認した(2026-09-20 追記)

README は「Transport-agnostic」の説明の直後に依存として
`picoruby-yaml` / `picoruby-vfs` / `picoruby-crc` / `picoruby-pack` を挙げているが、
**これは不正確。** `mrbgems/picoruby-dfu/mrbgem.rake` の実物を見ると:

```ruby
spec.add_dependency 'picoruby-env'
spec.add_dependency 'picoruby-yaml'
spec.add_dependency 'picoruby-crc'
if build.femtoruby?
  spec.add_dependency 'picoruby-pack'
elsif build.picoruby?
  spec.add_dependency 'mruby-pack'
end
```

`picoruby-vfs` は declare されていない。README の記述と実装がずれている
(README のほうが古いか、書き手の記憶違いと思われる)。

**この4つの依存の rp2040 対応も確認した:**

| gem | 中身 | rp2040 対応 |
|---|---|---|
| `picoruby-env` | `src/mruby` + `ports/rp2040` あり | ○ (port 実在) |
| `picoruby-yaml` | `mrblib` のみ、`src`/`ports` 無し | ○ (pure Ruby、VM 非依存) |
| `picoruby-crc` | `src/mruby` のみ、`ports` 無し | ○ (VM 依存の C だけで board 非依存) |
| `mruby-pack` | mruby 本体寄りの標準 gem | ○ (upstream mruby 由来、board 非依存) |

**さらに、`vendor/picoruby` 自身が持つ `picoruby-dfu` 用のテストを host で実際に
走らせて確認した** (このharnessの `rake test:host` とは別に、upstream 自身の
`rake test:gems:picoruby[picoruby-dfu]` を `vendor/picoruby` の中で直接実行):

```
MetaUtilTest:            success: 17, failure: 0
MetaYamlRoundtripTest:   success: 6,  failure: 0
OtaConfirmTest:          success: 7,  failure: 0
UpdaterReceiveTest:      success: 16, failure: 0
Total: success: 46, failure: 0, exception: 0, crash: 0, skip: 0
```

`UpdaterReceiveTest` は `DFU::Updater#receive` のヘッダ解析・CRC・A/B スロット遷移を
実際に動かして検証している(ソースを読んだだけの推測ではない)。

**これで残った不確実性は縮んだ:** 依存4つは存在も rp2040 対応も確認済みで、
ロジック自体も host 上の実行で確認済み。まだ確認できていないのは
**`arm-none-eabi-gcc` での実クロスコンパイルが通るか**と、**rp2040 の実ファイルシステム
(littlefs 経由の `File`)でも同じ挙動になるか**の2点だけ — host は posix の
`mruby-io`/`mruby-dir` 経由、rp2040 は別の port を通る。この差はコードを読むだけでは
埋まらず、`rake rp2040:build` を実機・ツールチェインが揃ったセッションで通すまで残る。

## BLE のスループット(未検証)

ATT MTU 依存の `notify_chunk_size`(既定 20 バイトペイロード)が、`.rb`/`.mrb` の
実用的な転送時間としてどの程度かは実機未計測。

## `bash0C7/picoruby-ble-verify` (private) との関係

docs/research/picoruby-usb-survey.md に記録済みの通り、このリポジトリには BLE 検証の
資産 (`stages/`) がある。今回の調査で分かった upstream の状態(`picoruby-ble` /
`picoruby-ble-uart` がすでに pico2_w build_config 入り)を踏まえると、あちらの検証は
**この upstream gem 群を Pico 2 W 実機で検証したもの**である可能性が高い。
本セッションはそのリポジトリへのアクセス権が無いため未確認 — 次にアクセスできる
セッションで照合する。
