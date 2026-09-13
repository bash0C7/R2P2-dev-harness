# v1 設計仕様

R2P2-dev-harness が v1 で作るものの仕様。決定済みの事項だけを書く。
未決のものは末尾の「未決」に集める。

## 1. 何を作るのか

**PicoRuby を USB 周辺機器にするライブラリ**と、それを開発・検証するためのハーネス。

第1積荷は USB CDC-MIDI。これは「MIDI がやりたい」からではなく、
**descriptor の C 変更を伴わない唯一の USB 経路**だから選んでいる
(根拠は [research/picoruby-usb-survey.md](research/picoruby-usb-survey.md))。
先に器 — ライブラリの形、rake の共通インタフェース、無人検証の経路 — を
C に触らずに固め、中身は後から差し替える。

やりたかった USB HID ゲームコントローラーは v1 では作らない。
課題は [issues/gamepad.md](issues/gamepad.md) にまとめてある。

## 2. ライブラリの形

初期化・メインループ・片付けにそれぞれメソッドがあり、具体の処理はブロックで渡す。
USB 制御としての共通的なことはライブラリ内にカプセル化する。

```ruby
require "usb/peripheral/cdc_midi"

USB::Peripheral::CDCMIDI.new(idle_ms: 0).run do |dev|
  note = 60

  dev.setup do
    puts "USB MIDI connected"
  end

  dev.tick do |d|
    d.note_on(0, note, 100)
    d.idle(180)
    d.note_off(0, note)
    note = 72 <= note ? 60 : note + 1
  end

  dev.teardown do
    # 既定の後始末 (下記) のあとに呼ばれる
  end
end
```

ブロックは device を引数に受け取り、状態は呼び出し側の local 変数に置く。
`instance_eval` はしない — device の ivar とアプリの状態が同じ名前空間に同居すると、
ライブラリが ivar を1つ足しただけでアプリが壊れる。

### ライブラリがカプセル化するもの

アプリ側に書かせないもの。ここが「つど作らなくてよい」の実体になる。

| 項目 | 中身 | 実体 |
|---|---|---|
| 接続待ち | `connected?` が真になるまで待つ。刻みは `connect_poll_ms` | `#wait_for_connection` |
| USB task の駆動 | `Machine.tud_task` を回す責任をループが持つ | `#pump` |
| 切断の検出 | ループ中に `connected?` が偽になったら tick を止め、再接続を待つ | `#session` |
| 例外の扱い | tick が raise しても後始末と teardown を必ず通してから投げ直す | `#session` の `ensure` |
| 後始末 | 下記 | `#restore_host_state` |

subclass が実装するのは `#connected?` と `#restore_host_state` の2つだけ。
`#pump` と `#idle` は下回りで、テストではここを差し替える。

### 片付け (teardown) は要る

USB デバイスとしての物理的な終了処理は不要 — USB は host 主導で、
デバイス側から detach する手続きは無い。**それでも teardown は要る。**
理由は USB ではなくアプリの状態にある:

- MIDI: 鳴らしっぱなしの note が host 側に残る。All Notes Off が要る
- HID: 押しっぱなしのキー / ボタンが host 側に残る。全解放が要る

つまり teardown の役目は「USB を畳む」ことではなく
**「host に残した状態を戻す」こと**。ライブラリが役ごとの既定の後始末を持ち、
ブロックはその後に走る追加分として扱う。ユーザーが何も書かなくても
stuck note / stuck key は起きない、が既定の挙動。

## 3. 置き場所と取り込ませ方

```
gems/picoruby-usb-peripheral/            器。pure Ruby、依存なし
gems/picoruby-usb-peripheral-cdc-midi/   CDC-MIDI の結線。器 + usb-cdc-midi に依存
  mrbgem.rake
  mrblib/
  test/                                  picotest
  sig/
build_config/                            gemdir: で gems/ を指す build_config
rakelib/                                 rake タスク
examples/rp2040/                         example アプリ (.rb)
vendor/picoruby/                         rake が取得する。commit しない
```

**器と結線は別の gem に分ける。** `picoruby-usb-peripheral` は USB の具体を何も知らず、
依存も持たない。MIDI の結線が要る build にだけ
`picoruby-usb-peripheral-cdc-midi` が入る。器の側に MIDI 依存を持たせると、
HID しか使わない build にまで MIDI が付いてくる。

build_config から `conf.gem gemdir: "#{HARNESS_ROOT}/gems/<name>"` で指す。
mruby の build system は `gemdir:` を受け付ける (upstream の `build_config/picoruby-wasm.rb` に前例)。

**build_config は upstream のものを複製しない。** ハーネスの build_config は
upstream の build_config を `load` して、そこへ `conf.gem gemdir:` を足すだけにする。
複製すると upstream の変更に追従できず、静かに古くなる。

**代償が2つある。**

1. upstream の `rake test:gems:picoruby` は `MRUBY_ROOT/mrbgems/picoruby-*` しか
   glob しない (`tasks/picoruby/test.rake` の `collect_gems`)。`gemdir:` で外から差した
   gem は build には乗るが**テストには拾われない**。ホストテストの runner は本 repo が
   自前で持つ (§5)
2. upstream の r2p2 firmware task は build_config の path を
   `build_config/r2p2-<vm>-<board>.rb` と決め打つので、ハーネスの build_config を渡す口が無い。
   `rake setup` / `rake refresh` が `vendor/picoruby/build_config/` にその名前の
   **shim を生成**し、upstream の原本は `*.upstream.rb` として隣に退避する。
   vendor を書き換えるのはこの1点だけで、何を書き換えたかは
   `rakelib/vendor.rake` の `vendor:overlay` に書いてある

## 4. rake の共通インタフェース

ターゲットが増えても同じ名前で同じことが起きる、を満たす最小集合。

| タスク | 意味 | 状態 |
|---|---|---|
| `rake setup` | `vendor/picoruby` を取得し、submodule と overlay を張る | 実装済み |
| `rake refresh` | 既存の `vendor/picoruby` を取得し直す | 実装済み |
| `rake test:host` | ホストで picotest を回す。実機不要 | 実装済み |
| `rake clean` | build 生成物を捨てる (vendor は残す) | 実装済み |
| `rake <target>:setup` | そのターゲットにだけ要る重い submodule を取る | rp2040 実装済み |
| `rake <target>:build` | firmware / 実行ファイルを作る | rp2040 実装済み (実機未検証) |
| `rake <target>:flash` | 実機へ焼く (§6) | rp2040 実装済み (実機未検証)。BOOTSEL は人間 |
| `rake <target>:upload[src,dst]` | `.rb` を board へ転送する | rp2040 実装済み (実機未検証) |
| `rake <target>:run[app,secs]` | 実機でアプリを走らせ、ログを取る | rp2040 実装済み (実機未検証) |
| `rake <target>:reboot` | board をリブートする | rp2040 実装済み (実機未検証) |
| `rake <target>:verify` | build → flash → run → **判定**。これが green で完了 | 未実装。判定が無い |

`<target>` は v1 では `rp2040` と `darwin`。darwin はまだ何も無い (積荷3)。

環境変数は `PICORUBY_REPO` / `PICORUBY_REF` (取得元と ref) と `SKIP_BUILD`
(`test:host` で再 build を飛ばす)。

**未実装のタスクは、黙って通ったふりをせずに落とす。** 何が無くて、代わりに
今は何をするのかを message に書く。実機まで通って初めて完了 (§5) という線引きは、
「実機の task が無い」を「実機は要らない」に読み替えられた瞬間に消える。

`verify` だけが最後まで残っているのは、**判定する相手役がまだ無い**から。
焼いて走らせるところまでは道具が揃っても、Mac 側で「MIDI デバイスとして列挙されたか」
「送った event を受け取れたか」を見る口が無ければ、verify は「落ちなかった」以上の
ことを言えない。それは完了の線引きとしては使えない。

`build/<target>/` の stale 化は R2P2-darwin と同じ方法で防ぐ:
`vendor/picoruby` の SHA、build_config の digest、**ハーネスの gem の中身の digest** を
stamp に記録し、
一致しなければ dir ごと捨てて再 build する。mruby の compile rule は `.c` の mtime しか
見ないので、取得し直した tree の方が既存 `.o` より古いと何も再 compile されず、
成功したと言いながら前の archive を stage する。

## 5. テストの範囲

**2層。実機まで通って初めて完了。**

### ホスト層 (`rake test:host`, CI に載る)

picotest で回す。対象は C に依存しない部分:

- report map / descriptor の組み立て結果がバイト列として正しいか
- payload の組み立て (MIDI event のエンコード、HID report の bit 詰め)
- setup → tick → teardown の呼ばれ方、切断時の遷移、例外時に teardown が通ること

C の向こう側 (`USB::CDC._midi_write` など) は picotest の stub / mock で差し替える。
upstream の `picoruby-usb-cdc-midi/test/midi_output_test.rb` が
`write_bytes` を subclass で差し替える形を取っているので、これに倣う。

runner は本 repo が持つ (§3 の代償)。temp build_config を作り、
`picoruby-test` 相当のホストビルドを起こし、picotest を走らせる。

### 実機層 (`rake <target>:verify`)

Pico 2 W に焼き、Mac を相手役にして、両側のログで判定する。
**実機の挙動は実機で実証するまで「動いた」と書かない。**
実機が使えない環境 (CI、web session) では、その旨を1行報告して完了宣言を保留する。

CDC-MIDI の判定材料: Mac 側で MIDI デバイスとして列挙されること、
送った event が受信できること、teardown 後に stuck note が残らないこと。

## 6. 無人の焼き込みと検証 (目玉)

既存の資産は private repo `bash0C7/picoruby-ble-verify` の `pico2w/` にある
(picomodem / pmput / rsh / runapp / stages)。**これを本 repo に取り込む。**
そのうえで、いま人間に頼っている操作を減らす。

取り込み済みのもの: `tools/pico2w/` に device helper 4本 + reboot script。
BLE 検証に依る `stages/` は持ってきていない (あちらの repo のもの)。
`rake rp2040:upload` / `run` / `reboot` / `flash` がこれらを呼ぶ。
**どれもまだ実機で動かしていない。** macOS の `ioreg` と `serialport` gem が要る。

### いま人間にしか頼めない3つ

1. **BOOTSEL 書き込み** — USB を抜き、BOOTSEL を押したまま挿し、離す
2. **ハング復旧の USB 抜き差し**
3. **Mac の Bluetooth 許可ダイアログ** (BLE を使う検証のときだけ)

### 無人化の段取り

| 段階 | 内容 | 人間の関与 |
|---|---|---|
| G0 | 現状。`picotool load -x` で焼く | 毎回 BOOTSEL |
| G1 | firmware 側に「BOOTSEL モードへ落ちる」口を作る | **初回だけ** BOOTSEL |
| G2 | ハング時の電源サイクル | 未決 (機材依存) |

**G1 の方式は Mac ローカルの Claude session で既に確立している。**
本 repo ではそれを前提として扱い、**改修は Mac 側で行う**。
web session から再設計・再検討はしない。申し送りは
[handoff-to-mac.md](handoff-to-mac.md)。

背景としての事実だけ残す: 現行 R2P2 firmware は reset interface を持たないので
`picotool reboot` が効かず、1200-baud touch も効かない。
R2P2 shell 経由で BOOTSEL モードへ落とせる口があれば、以後の焼き直しは無人で回る。

### 取り込むときに落とさない知見

`picoruby-ble-verify` の SKILL.md が持っている、踏まないと分からない類のもの:

- **`/Volumes/RP2350` への `cp` は使わない。** マウント完了前に走ると
  `Device not configured` で失敗し、しかもボリュームは見えている。`picotool` は待つ
- **ポートを `/dev/cu.usbmodem*` の glob で選ばない。** USB を抜き差しするとノード名が変わり、
  ESP32 を同時に挿しているとそちらが先に並ぶ。しかも ESP32 はポートを開くとリセットされる。
  必ず USB の製品名から引く (`ioreg -w 0 -r -n "R2P2" -l | grep IOCalloutDevice`)
- **R2P2 shell は入力を Ruby として評価しない。** `Machine.reboot` と打っても何も起きない。
  スクリプトを `/home/` に置いて実行する
- **マスストレージはマウントされない。** ファイル転送は PicoModem のみ
- `stackchan-picoruby` の `Deploy::Picomodem.upload` をそのまま呼んではいけない。
  RP2350 は DTR/RTS でリセットされないので起動バナー待ちでタイムアウトする

## 7. 積荷の順序

1. **器を立てる** — `gems/picoruby-usb-peripheral` の setup/tick/teardown、
   `rake setup` / `test:host` / `rp2040:verify`、CDC-MIDI の example 1本
2. **無人化 G1** — Mac 側の改修を待って、それを使う `rp2040:flash` を本 repo に置く
3. **darwin ターゲット** — Mac 側を同じ rake インタフェースに載せる
4. (v1 外) ESP32、USB HID ゲームパッド

## 8. 未決

無人化 G1 はここに無い。方式が確定済みで、実装が Mac 側にあるため
([handoff-to-mac.md](handoff-to-mac.md))。

`rake test:host` の runner の実装量も、もう未決ではない。upstream の
`Picotest::Runner` をそのまま require して使えるので、ハーネスが持つのは
「temp ではない build_config で host VM を建てて、gem ごとに Runner を回す」
30 行ほど。`collect_gems` の代わりは要らなかった。

- **ハング復旧 (G2) の機材。** USB hub の電源制御 (`uhubctl`) が Mac 側で効く hub があるか、
  外部リレーを足すか、firmware の watchdog で代替するか
- **darwin ターゲットで USB 周辺機器の何を検証するのか。** Mac は host 側なので、
  「相手役」としての役割 (MIDI 受信、HID 列挙の確認) に限るのか、
  R2P2-darwin のように Mac 上で PicoRuby を走らせる側も持つのか
