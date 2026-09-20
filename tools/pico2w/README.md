# Pico 2 W を無人で触るための helper

`bash0C7/picoruby-ble-verify` の `pico2w/scripts/` から、BLE 検証に依らない
device helper だけを持ってきたもの。あちらでは Pico 2 W で動いている。
本 repo からは `rake rp2040:flash` / `upload` / `run` / `reboot` 経由で、どれも実機で通した。

| file | 何をするか |
|---|---|
| `pmput.rb` | ローカルの `.rb` を `/home/<name>.rb` へ転送する |
| `rsh.rb` | R2P2 shell にコマンドを1つ打って N 秒読む |
| `runapp.rb` | `/home/<name>.rb` を実行して N 秒キャプチャし、Ctrl-C で止める |
| `reboot_app.rb` | board に置いて実行するとリブートする 2 行 |
| `usbboot_app.rb` | board に置いて実行すると BOOTSEL へ落ちる。`Machine.usb_boot` 入りの firmware が要る |
| `tmo.rb` | コマンドに壁時計の上限を掛け、process group ごと SIGKILL する |
| `interrupt.rb` | shell の port に Ctrl-C を送る。自動起動した `/home/app.rb` を止めて `$>` を出す |
| `shell_ok.rb` | 呼び出し元を固まらせずに shell の生存を確かめる。`$>` プロンプトが返れば `OK`、それ以外は `DEAD` |
| `boot_state.rb` | 再列挙直後の CDC0 出力を読み、`shell` / `app` / `hung` / `unknown` のどれかを数秒で答える。`/home/app.rb` が自動起動する board で、出ない `$>` を盲目に待たないために使う |

PicoModem プロトコル (`picomodem.rb`。`bash0C7/stackchan-picoruby` の `lib/deploy/picomodem.rb` の写し) と
端末問い合わせへの応答 (`term.rb`。行エディタの `\e[6n` / `\e[5n` に答える) は、
ESP32 の `tools/esp32/` と共有するので `tools/common/` に置いてある。
`pmput.rb` が `picomodem.rb` を、`rsh.rb` / `runapp.rb` / `shell_ok.rb` / `boot_state.rb` が `term.rb` を使う。

`serialport` gem が要る。

## 踏まないと分からないこと

- **ポートを `/dev/cu.usbmodem*` の glob で選ばない。** USB を抜き差しするとノード名が
  変わり、ESP32 を同時に挿しているとそちらが先に並ぶ。しかも ESP32 はポートを開くと
  リセットされる。3本とも USB の製品名から引く
  (`ioreg -w 0 -r -n "R2P2" -l | grep IOCalloutDevice`、小さい方が CDC0 = shell)
- **マスストレージはマウントされない。** ファイル転送は PicoModem のみ
- **`stackchan-picoruby` の `Deploy::Picomodem.upload` をそのまま呼んではいけない。**
  RP2350 は DTR/RTS でリセットされないので、起動バナー待ちで必ずタイムアウトする。
  `pmput.rb` はそのリセット手順を外してある
- **R2P2 shell は入力を Ruby として評価しない。** プロンプトに `Machine.reboot` と
  打っても何も起きない。`reboot_app.rb` を `/home/` に置いて実行する
- **行エディタは接続のたびに `\e[6n` と `\e[5n` を送り、応答まで打鍵を捨てる。**
  答えないとコマンド行が黙って消える。port を開くたびに `Term.settle`、read ごとに `Term.answer`
- **wedge した board への blocking な serial open は macOS で返らず、SIGTERM も効かない。**
  serial を開くものは `tmo.rb` 越しに回すか、`shell_ok.rb` のように fork した子で O_NONBLOCK で開く
- ハングしたら (CDC は列挙されているのに無音) 復旧は USB 抜き差しだけ。
  `picotool reboot` はこの firmware に reset interface が無いので効かず、
  1200-baud touch も効かない。BOOTSEL へ落とすのは `usbboot_app.rb` (docs/spec.md §6 G1)
