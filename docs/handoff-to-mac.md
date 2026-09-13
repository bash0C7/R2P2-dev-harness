# 申し送り: Mac 側でやること

web session (Claude Code on web) からは実機も Mac も触れない。
ここは **Mac ローカルの Claude session に渡す作業**の一覧。

## 1. `rake rp2040:*` を本 repo から実機で通す

無人化 G1 (`Machine.usb_boot` で BOOTSEL へ落とす) は本 repo に入っている。
方式・手順・落とし穴は [spec.md](spec.md) §6。patch と helper は `bash0C7/picoruby-ble-verify` で
Pico 2 W を相手に確認済みだが、**本 repo の rake からは1度も動かしていない。**

```sh
rake setup && rake rp2040:setup
rake rp2040:build                          # firmware-patches/ を当てて build し、戻す
rake rp2040:flash                          # 初回だけ BOOTSEL は人間、以後は無人
rake rp2040:upload[app.rb,/home/app.rb]
rake rp2040:run[examples/rp2040/midi_scale.rb,20]
rake rp2040:reboot
```

確かめること:

- 初回: patch 無し firmware の board で flash が人手 BOOTSEL を頼み、焼けて shell が応答する
- 2回目以降: board に触らずに flash が完走する
- build の後に vendor/picoruby に patch が残っていない (`git -C vendor/picoruby status`)
- Claude Code の sandbox 内から picotool と serial が USB に触れるか。触れなければ sandbox 外で回す

## 2. ハング復旧 (G2) の機材選定

USB hub の電源制御 (`uhubctl`) が手元の hub で効くか、外部リレーを足すか、
firmware の watchdog で代替するか。**手元の機材を見ないと決まらない。**
`picoruby-ble-verify` での実績は [spec.md](spec.md) §8。

## 3. 判定する相手役 (verify に要る)

`rake rp2040:verify` だけがまだ落ちるようにしてある。焼いて走らせる道具は揃ったが、
**Mac 側で判定する口が無い**から。これが書けると verify が閉じる。

[spec.md](spec.md) §5 のとおり、完了条件は実機まで通って green。
CDC-MIDI の判定材料:

- Mac 側で MIDI デバイスとして列挙されること
- 送った event が受信できること
- teardown 後に stuck note が残らないこと

web session はホスト層 (`rake test:host`) までしか green にできない。
そこで止まったら「実機未検証」と明示して完了宣言を保留する。
