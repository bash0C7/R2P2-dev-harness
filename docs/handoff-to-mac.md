# 申し送り: Mac 側でやること

web session (Claude Code on web) からは実機も Mac も触れない。
ここは **Mac ローカルの Claude session に渡す作業**の一覧。
web 側はこれらを前提として扱い、再設計しない。

## 1. 無人化 G1 — reset interface の不在への対処

**方式は Mac ローカルの session で既に確立済み。** web 側で再検討しない。
残っているのは firmware の改修そのもので、それは Mac 側で行う。

背景の事実だけ再掲する (web 側が同じ結論を掘り直さないために):

- 現行 R2P2 firmware は reset interface を持たないので `picotool reboot` が効かない
- 1200-baud touch も効かない
- マスストレージはマウントされないので、ファイル転送は PicoModem のみ
- R2P2 shell は入力を Ruby として評価しない。スクリプトを `/home/` に置いて実行する

改修が入ったら、web 側で引き取るのは以下:

- `rake rp2040:flash` を「BOOTSEL モードへ落とす → `picotool load -x`」の手順に書き換える
- [spec.md](spec.md) §6 の段取り表の G1 行を、人間の関与「初回だけ BOOTSEL」で確定させる
- 確立した方式の実体 (どこに何を足したか) を [spec.md](spec.md) §6 に1節として記録する

## 2. `tools/pico2w/` を実機で通す

`bash0C7/picoruby-ble-verify` の `pico2w/scripts/` から device helper 4本
(`picomodem.rb` / `pmput.rb` / `rsh.rb` / `runapp.rb`) と reboot script は
**もう `tools/pico2w/` に入っている**。rake からも呼べる:

```sh
rake rp2040:flash                          # BOOTSEL は人間、そのあと picotool
rake rp2040:upload[app.rb,/home/app.rb]
rake rp2040:run[examples/rp2040/midi_scale.rb,20]
rake rp2040:reboot
```

**どれも実機で1度も動かしていない。** 残っているのはそこ。`serialport` gem と
macOS の `ioreg` が要る。BLE 検証に依る `stages/` は持ってきていないので、
必要なら向こうの repo から。落としてはいけない知見は
[spec.md](spec.md) §6 と `tools/pico2w/README.md` にある。

## 3. ハング復旧 (G2) の機材選定

USB hub の電源制御 (`uhubctl`) が手元の hub で効くか、外部リレーを足すか、
firmware の watchdog で代替するか。**手元の機材を見ないと決まらない。**

## 4. 判定する相手役 (verify に要る)

`rake rp2040:verify` だけがまだ落ちるようにしてある。焼いて走らせる道具は揃ったが、
**Mac 側で判定する口が無い**から。これが書けると verify が閉じる。

[spec.md](spec.md) §5 のとおり、完了条件は実機まで通って green。
CDC-MIDI の判定材料:

- Mac 側で MIDI デバイスとして列挙されること
- 送った event が受信できること
- teardown 後に stuck note が残らないこと

web session はホスト層 (`rake test:host`) までしか green にできない。
そこで止まったら「実機未検証」と明示して完了宣言を保留する。
