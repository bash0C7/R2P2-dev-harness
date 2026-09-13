# Pico 2 W を無人で触るための helper

`bash0C7/picoruby-ble-verify` の `pico2w/scripts/` から、BLE 検証に依らない
device helper だけを持ってきたもの。**まだ検証していない。**
実機が要るので、動かすのは Mac 側のセッション ([../../docs/handoff-to-mac.md](../../docs/handoff-to-mac.md))。

| file | 何をするか |
|---|---|
| `picomodem.rb` | PicoModem プロトコル。`bash0C7/stackchan-picoruby` の `lib/deploy/picomodem.rb` の複製 |
| `pmput.rb` | ローカルの `.rb` を `/home/<name>.rb` へ転送する |
| `rsh.rb` | R2P2 shell にコマンドを1つ打って N 秒読む |
| `runapp.rb` | `/home/<name>.rb` を実行して N 秒キャプチャし、Ctrl-C で止める |
| `reboot_app.rb` | board に置いて実行するとリブートする 2 行 |

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
- ハングしたら (CDC は列挙されているのに無音) 復旧は USB 抜き差しだけ。
  `picotool reboot` はこの firmware に reset interface が無いので効かず、
  1200-baud touch も効かない
