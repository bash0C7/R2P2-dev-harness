# R2P2-dev-harness

bash0C7 が個人で PicoRuby の装置を作るための知見と rake タスクを集約する repo。実機を焼いて検証する rake タスクは `rakelib/` と `tools/pico2w/`。
PicoRuby を USB 周辺機器にするライブラリ (`gems/`) と example (`examples/`) は、その上に載せた実例のひとつ。
対象は Pico 2 W (`rake rp2040:*`、`tools/pico2w/`) と ESP32 の M5Stack Chain DualKey (`rake esp32:*`、`tools/esp32/`)。
両者が共有するコードは `tools/common/`。

- 設計と決定事項は [docs/spec.md](docs/spec.md) が single source of truth。実機の罠は Pico 2 W が §6、ESP32 が §9 にまとめてある
- 残っている作業は GitHub issues (`gh issue list`)

## 作業の規律

- **完了の線引きは実機。** `rake test` (ホスト) が green でも、実機で走らせるまで「動いた」と書かない
- **`vendor/picoruby` は生成物。** commit しない。変更は `firmware-patches/` (build 中だけ当てる) か build_config の overlay で行う
- **Pico 2 W は Claude が触る。** `rake rp2040:build` / `flash` / `upload` / `run` / `reboot` は Bash から直接回せる
  (sandbox を外さずに USB へ届く)。人に頼むのは物理操作 (初回の BOOTSEL、wedge 時の USB 抜き差し、ボタン押下) と
  画面の目視だけ
- **`upload` / `run` は `.rb` を mrbc で `.mrb` にして送る (既定)。** 板上で prism が `.rb` を compile すると heap を食い `NoMemoryError` で落ちる (DualKey で実測、docs/spec.md §9)。`.rb` のまま送るのは `HARNESS_SEND_RB=1`
- **serial を開くものは `tools/pico2w/tmo.rb` で時間を区切る。** wedge した board への open は macOS で返らない
- **board には `/home/app.rb` が置いてあり、起動時に自動実行されることがある。** その間 shell は黙る。
  `upload` / `run` / `reboot` は `$>` が返らなければ Ctrl-C で止めてから shell を使う。
  `flash` / `reboot` の直後は `tools/pico2w/boot_state.rb` が起動状態 (shell / app / hung) を判定し、app が上がっていれば止めない。
  Ctrl-C で止めた app の `teardown` は走らないので、押しっぱなしのボタンや鳴りっぱなしの note が host に残り得る
- **shell の生存は `tools/pico2w/shell_ok.rb` (ESP32 は `tools/esp32/shell_ok.rb`) で見る。** `$>` プロンプトが返るかで判定し、bytes が返っただけでは生きていない
- **ESP32 (M5Stack Chain DualKey) も `rake esp32:*` を Bash から回す。** build / flash は `../R2P2-ESP32` の checkout (`R2P2_ESP32_REPO` で上書き) の rake に委ねる。
  ESP32 の罠は [docs/spec.md](docs/spec.md) §9 にあり、次の3つは特に踏みやすい:
  - **ポートを開くだけでリセットされる。** ポートは `/dev/cu.usbmodem*` の glob でなく `ioreg` の製品名で選ぶ (`tools/esp32/` の各 script がそうしている)
  - **`$>` の2文字は起動時の ESP-IDF boot log に偶然出る。** プロンプト判定は banner の後に受信した bytes だけを見る
  - **短時間に reset を繰り返すと無応答になることがある。** 復旧は USB の抜き差し (物理操作なので人に頼む)
- firmware の build は数分かかる。長い処理は `nohup ... & disown` で切り離し、ログを scratchpad に書く
