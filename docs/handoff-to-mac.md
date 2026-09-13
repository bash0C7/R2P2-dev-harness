# 申し送り: Mac 側でやること

web session (Claude Code on web) からは実機も Mac も触れない。
ここは **Mac ローカルの Claude session に渡す作業**の一覧。

## 1. `rake rp2040:upload` / `run` / `reboot` を実機で通す

`rake rp2040:build` と `rake rp2040:flash` は Pico 2 W 実機で通った。flash は BOOTSEL 押下なし
([spec.md](spec.md) §6)。task として残っているのは次の3つ:

```sh
rake rp2040:upload[app.rb,/home/app.rb]
rake rp2040:run[examples/rp2040/midi_scale.rb,20]
rake rp2040:reboot
```

`run` は `runapp.rb`、`reboot` は `rsh.rb` を blocking open で呼ぶ。wedge した board で止まらないよう
`tmo.rb` を掛けるかは、通してみてから決める。

compiler の submodule を旧 pin に固定している ([spec.md](spec.md) §6)。
picoruby の `mrbgems/mruby-compiler` の pin が `MRC_PRISM_ARENA_BLOCK` の `#ifndef` を含んだら、
固定を外して `MRC_PRISM_ARENA_BLOCK=4096` の define に切り替える。

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
