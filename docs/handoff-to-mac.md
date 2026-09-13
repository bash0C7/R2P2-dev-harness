# 申し送り: Mac 側でやること

web session (Claude Code on web) からは実機も Mac も触れない。
ここは **Mac ローカルの Claude session に渡す作業**の一覧。

## 1. compiler の submodule の固定を外す時期を見る

compiler の submodule を旧 pin に固定している ([spec.md](spec.md) §6)。
picoruby の `mrbgems/mruby-compiler` の pin が `MRC_PRISM_ARENA_BLOCK` の `#ifndef` を含んだら、
固定を外して `MRC_PRISM_ARENA_BLOCK=4096` の define に切り替え、実機で shell まで上がるか確かめる。

## 2. ハング復旧 (G2) の機材選定

USB hub の電源制御 (`uhubctl`) が手元の hub で効くか、外部リレーを足すか、
firmware の watchdog で代替するか。**手元の機材を見ないと決まらない。**
`picoruby-ble-verify` での実績は [spec.md](spec.md) §8。

## 3. 判定する相手役 (verify に要る)

`rake rp2040:verify` だけがまだ落ちるようにしてある。焼いて走らせる道具は揃ったが、
**Mac 側で判定する口が無い**から。これが書けると verify が閉じる。

[spec.md](spec.md) §5 のとおり、完了条件は実機まで通って green。
CDC-MIDI の判定材料 (Mac からは MIDI 機器ではなくシリアルポートとして見える):

- 3本目の CDC を読んで、送った event が受信できること
- teardown 後に stuck note が残らないこと

web session はホスト層 (`rake test:host`) までしか green にできない。
そこで止まったら「実機未検証」と明示して完了宣言を保留する。
