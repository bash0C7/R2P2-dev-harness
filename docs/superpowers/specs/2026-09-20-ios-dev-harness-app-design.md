# iOS 開発ハーネスアプリ — 設計

元issue: なし(口頭ブレストのみ。今回は issue を作らない)

## 目的

iPhone / iPad 単体で PicoRuby (R2P2) 実機のコード転送・実行・デバッグができ、
実機が無くても GPIO / LED をエミュレーションして Ruby コードを試せる
「開発ハーネスアプリ」を作る。母艦としての Mac を必須にしない。

## 前提として確定している技術的制約

- **USB CDC シリアルは iOS から開けない。** MFi 認証(Apple 発行チップ)無しに
  任意の USB シリアルデバイスをアプリへ開放する public API が iOS には無い。
  稼働中の R2P2 shell への `rake rp2040:upload`/`run` と同じ経路(USB CDC +
  PicoModem プロトコル、docs/spec.md §6)は iOS に移植できない
- **BOOTSEL 中の R2P2 は標準 USB Mass Storage (RPI-RP2) として列挙する。**
  USB-C の iPad (2018 3rd gen 以降)や USB-C/Lightning + カメラアダプタの iPhone
  なら、Files アプリ / `UIDocumentPickerViewController` 経由で `.uf2` を書き込める
- **ファーム(C)のクロスビルドは iOS 上では不可能。** GitHub Actions に丸投げする
- **picoruby は `.rb` を実行時に透過的にバイトコード化して動かす。** mrbc による
  事前コンパイルは firmware ビルド時の最適化手段であって、`.rb` を動かすのに
  必須ではない。「実機なし Playground」に要るのは mrbc 単体ではなく、
  **picoruby のホストビルド(VM + コンパイラ一体)** そのもの
- **BLE UART の転送路はすでに upstream にあり、C の新規実装が要らない。**
  調査の詳細は [../research/picoruby-ble-dfu-survey.md](../../research/picoruby-ble-dfu-survey.md)。
  要点だけここに転記する:
  - `picoruby-ble` (central/peripheral/GATT、rp2040 の BTstack+CYW43 port 込み)と
    `picoruby-ble-uart` (Nordic UART Service、pure Ruby)は
    **`build_config/r2p2-picoruby-pico2_w.rb` にすでに `conf.gem core:` で入っている**。
    このharnessが焼いている firmware に元から入っている
  - `picoruby-dfu` (A/B スロット・自動ロールバック付きの OTA アップデータ、
    `receive(io)` が transport-agnostic で `BLE::UART` をそのまま渡せる)は
    upstream にあるが pico2_w の build_config にはまだ無い。1行の
    `conf.gem core: 'picoruby-dfu'` で足せる見込み
  - `example/ble_irb.rb` (upstream) が `Sandbox` + `BLE::UART` で
    「BLE 越しに Ruby 一行を打って結果を受け取る」実例そのもの

この最後の発見で、当初「BLE トランスポートは private repo (`picoruby-ble-verify`) や
新規 C 実装が要る」と見ていた前提が変わった。**この harness の仕事は、新しい BLE
transport を作ることではなく、すでにある `picoruby-ble` / `picoruby-ble-uart` /
`picoruby-dfu` を配線して実機で検証することに縮む。**

## 決定事項(brainstorming で詰めた問い)

| 問い | 決定 |
|---|---|
| 転送経路 | BLE (`BLE::UART`) をメイン経路にする。USB は BOOTSEL 中の `.uf2` 書き込み(ファーム本体の更新)だけに限定 |
| アプリコード(`.rb`/`.mrb`)の転送・イテレーション | `picoruby-dfu` の `DFU::Updater` をそのまま使う。開発中の速いイテレーションは `path: "/home/app.rb"` で A/B スロットを経由せず直書き、リリース相当の更新は A/B スロット経由(自動ロールバック付き)を使う、の2モードで運用する |
| ファーム(C ランタイム)自体の無線更新 (OTA) | v1 スコープ外。`picoruby-dfu` は Ruby アプリ層の更新であって `vendor/picoruby` が吐く `.uf2` 本体の更新ではない、という区別を維持する。BLE は BOOTSEL へのトリガー(既存の `Machine.usb_boot` を BLE 越しに呼ぶ)だけ担当し、実際の書き込みは有線 MSC 経由のまま |
| 実機なし Playground の実装方式 | picoruby のホストビルド(`build_config/host-test.rb` 系列と同じ考え方)を iOS 向けにクロスビルドし、`GPIO`/`LED` などを模擬するスタブ C 実装に差し替える。`.rb` はソースのまま渡せる(透過コンパイルのため、mrbc 単体の移植は不要) |
| Swift/Xcode プロジェクト本体の置き場所 | 新規 sibling repo(`R2P2-ios-workbench` 想定)。ESP32 が `R2P2-ESP32` を sibling repo にして本 harness から `rake esp32:*` で委譲しているのと同じパターン(docs/superpowers/specs/2026-09-15-esp32-second-target-design.md)。**このリポジトリの新規作成はユーザーの判断が要るため、本ブレストでは決定のみ行い、作成は次のタスクに送る** |
| BLE UART / DFU の実機検証の順番 | iOS アプリより先に、**Pico 2 W 実機(2枚あれば pico-to-pico、1枚なら Mac 側の BLE central 相当ツール)で `BLE::UART` の疎通と `DFU::Updater` の転送を検証する**。iOS の CoreBluetooth 実装はこの経路が実機で通ってから着手する。理由: R2P2 firmware 側に未知の罠がある可能性が高く(§6 の USB 罠の量を見ればわかる)、Xcode 環境が無いこのセッションでは firmware 側から先に固めるほうが手戻りが少ない |
| `bash0C7/picoruby-ble-verify` (private) の扱い | 中身は本セッションから見えない。次にアクセスできるセッションで、今回判明した upstream の `picoruby-ble`/`picoruby-ble-uart`/`picoruby-dfu` と重複する検証が無いか照合する。無条件の移植はしない(ESP32 の stackchan-picoruby の扱いと同様、必要な部分だけ) |

## アーキテクチャ

### コンポーネント

1. **iOS app**(将来の sibling repo, Swift/SwiftUI): エディタ + CoreBluetooth
   クライアント(`BLE::UART` の central 側を Swift で実装) + Playground ランタイム
   (組み込み picoruby ホストビルド) + Files 経由の `.uf2` 書き込み UI
2. **R2P2 ファーム側**(本 harness、build_config overlay の追記のみ、C 変更なし):
   `picoruby-ble` / `picoruby-ble-uart` は既存のまま。`picoruby-dfu` を追加する
   1行と、それを配線する `/home/` 常駐スクリプト(BLE UART を起動し、受信した
   バイト列を `DFU::Updater` か REPL 用 `Sandbox` へ振り分ける)
3. **Cloud build**(GitHub Actions): 本 harness 側は今まで通り `.uf2` を焼く側。
   iOS 向け picoruby ホストビルド(Playground 用の静的ライブラリ)は sibling repo
   側の CI が担当する想定

### データフロー

```
[開発イテレーション―毎回、BLE のみで完結]
iOS app --(BLE UART, GATT RX/TX)--> R2P2 (稼働中)
  受信データ → DFU::Updater(path: "/home/app.rb") で直書き → reboot or 明示 run
  または → Sandbox 経由で1行ずつ REPL 実行(example/ble_irb.rb と同型)

[ファーム(C)更新―低頻度、有線が要る]
GitHub Actions --(.uf2 artifact)--> iOS app がダウンロード
iOS app --(BLE)--> R2P2: 既存 Machine.usb_boot をトリガー(BOOTSEL へ落とす。BLE はここで死ぬ)
[USB ケーブル接続が必須になる]
iOS app --(Files / UIDocumentPickerViewController, USB MSC)--> RPI-RP2 ドライブへ .uf2 コピー
R2P2 自動リブート --(BLE advertising 再出現)--> iOS app が起動確認

[実機なし Playground]
iOS app 内蔵の picoruby (iOS 向けクロスビルド) が .rb をそのままロード・透過コンパイル・実行
GPIO/LED はスタブ C 実装が状態を保持し、SwiftUI が購読して描画
```

### 本 harness の役割とスコープ外

ESP32 と同じ「委譲」パターンを踏襲する。本 harness(R2P2-dev-harness)は Swift/Xcode
の実体を持たない:

- 持つもの: `picoruby-dfu` を有効にする build_config overlay の追記、BLE UART +
  DFU を配線する `/home/` 常駐スクリプト(`examples/rp2040/` に置く想定)、
  それを実機(Pico 2 W、可能なら2枚)で検証する手順、iOS 向けクロスビルドを
  蹴る rake タスク(sibling repo か GitHub Actions への委譲。ESP32 の
  `esp32_repo_dir`/`require_esp32_repo!` と同じ形)
- 持たないもの: Xcode プロジェクトそのもの、Swift コード、App Store 提出周りの一切

## 作業の規律

実装(docs/superpowers/plans/2026-09-20-ios-dev-harness-app.md の Task 1-2)を
このセッションで実際に進めて分かった、この件特有の規律事項。

- **「動く」の線引きは、この件でも実機。** `BleDevBridge::Framer` の picotest が
  host で全部 green でも、`BLE::UART` / `DFU::Updater` / `Sandbox` を配線した
  `examples/rp2040/ble_dev_bridge.rb` 自体は Pico 2 W 実機で1回も動かしていない
  ("実機で確かめるまで動いたと言わない" は docs/spec.md 全体の規律だが、この件は
  「pure logic は host で検証済み、IO を伴う配線は未検証」という**2段階の完了**に
  なりやすいので、コミットメッセージや PR で両者を混同しない)
- **BLE/DFU 側に新しい C は書かない、書きたくなったら立ち止まる。**
  `picoruby-ble` / `picoruby-ble-uart` / `picoruby-dfu` はすでに upstream に
  そろっている(docs/research/picoruby-ble-dfu-survey.md)。この件で C の変更が
  要ると思えた時点で、それは大抵「upstream の API を読み切れていない」サインであり、
  先に survey doc を疑い直す
- **`BleDevBridge::Framer` に `BLE`/`DFU`/`Sandbox` への依存を持たせない。**
  DFU のヘッダ書式(19バイト固定 + 署名長)を知っているのは
  `DFU::Updater.expected_size` であって、Framer 自身ではない —
  呼び出し側が block で渡す(`gems/picoruby-usb-peripheral` が USB の具体を
  何も知らない「器」であるのと同じ形。docs/spec.md §3「器と結線は別の gem に
  分ける」を BLE 版でも踏襲する)
- **`picoruby-dfu` はアプリ層(`/home/app.rb`)の更新であって、R2P2 の C
  ランタイム(`.uf2`)の更新ではない。** この区別をコード・コメント・コミット
  メッセージのどこでも混同しない。混同すると「BLE で OTA できる」が
  「ファーム自体を無線更新できる」に読み替えられて事実と違う期待を生む
- **`gems/*/mrbgem.rake` は ASCII のみ。** `rakelib/test.rake` の
  `require_name_of` が locale 依存の default external encoding で読むため、
  日本語コメントが1つ混ざるだけで無関係な gem の後で `rake test:host` 全体が
  落ちる(このセッションで実際に踏んだ。詳細と直した箇所は docs/spec.md §5)。
  `mrblib/` 側は従来通り日本語コメント可
- **`vendor/picoruby` の中で upstream 自身の rake タスクを直接叩くと、
  このharnessの `build/host/` を黙って壊すことがある。** `picoruby-dfu` の依存を
  upstream の `rake test:gems:picoruby[picoruby-dfu]` で検証したところ、
  そのタスクは自分専用の一時 build_config で `build/host/` を `rake clean` して
  作り直す — このharness自身の `rake test:host` と同じ場所を使うので、
  直後に `SKIP_BUILD=1 rake test:host` を叩くと `picoruby-ble-dev-bridge` を
  含まない別物の VM を「まだ有効」と誤認して全滅する(実際に踏んだ)。
  upstream 側の検証を挟んだら、`SKIP_BUILD` なしで `rake test:host` を
  もう一度通してから次に進む(詳細: docs/research/picoruby-ble-dfu-survey.md)
- **build_config への追記は、まず「本当にそこを直すべきか」を実装前に読み切る。**
  当初の計画は `rakelib/vendor.rake` の overlay task 自体を直す想定だったが、
  実際に読むと overlay は `build_config/rp2040-pico2_w.rb` を `load` するだけの
  薄い shim で、直すべきは harness 側の build_config 2 file
  (`build_config/rp2040-pico2_w.rb` / `build_config/host-test.rb`) だけだった。
  読まずに計画通り rakelib 側を触っていたら、要らない変更を1つ増やしていた

## スコープ外

- ファームウェア(C ランタイム)本体の OTA 無線更新
- iPhone/iPad での USB CDC シリアル対応(技術的に不可能と結論済み)
- App Store 配布・審査対応
- `picoruby-ble-verify` からの完全な引き剥がし(必要な部分だけ移植し、依存除去は別スコープ)
- ECDSA 署名検証を使った DFU の運用(v1 は CRC32 検証のみで足りる規模)

## 完了条件(このドキュメントが対象にする最初の一歩)

- `picoruby-dfu` を有効にした Pico 2 W 実機で、`BLE::UART` 経由の `DFU::Updater`
  (`path:` モード)で `/home/app.rb` を書き換えられ、reboot 後にそのアプリが動く
  ことを実機で確認する
- 上記が実機で通った段階で、iOS 側の sibling repo 着手をユーザーと相談する
  (Xcode/実機 iPhone・iPad が要るため、この harness の Linux セッションでは
  検証できない — 完了の線引きは実機、という docs/spec.md の規律をここでも守る)

## 未決

- `picoruby-dfu` の依存 gem (`picoruby-yaml`/`picoruby-vfs`/`picoruby-crc`/
  `picoruby-pack`) が pico2_w の既存 gembox で足りるかは `rake rp2040:build`
  を実際に通すまで確定しない
- BLE のスループット(ATT MTU 依存の `notify_chunk_size`)が `.rb`/`.mrb` の
  実用的な転送時間としてどの程度かは実機計測が要る
- `picoruby-ble-verify` (private) との重複範囲
- sibling repo `R2P2-ios-workbench` を実際に作るかどうか、作るタイミング
