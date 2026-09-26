# v1 設計仕様

R2P2-dev-harness が v1 で作るものの仕様。決定済みの事項だけを書く。
未決のものは末尾の「未決」に集める。

## 1. 何を作るのか

bash0C7 が個人で **PicoRuby の装置を作るための知見と rake タスクを集約する** repo。
中心は実機を焼いて検証する rake タスクと、実機で踏んだ罠 (§4, §6)。
その上に載せる装置の実例のひとつが、**PicoRuby を USB 周辺機器にするライブラリ** (`gems/`) と example (`examples/`)。

USB 周辺機器のライブラリの第1積荷は USB CDC-MIDI。これは「MIDI がやりたい」からではなく、
**descriptor の C 変更を伴わない USB 経路**だから選んでいる
(根拠は [research/picoruby-usb-survey.md](research/picoruby-usb-survey.md))。
R2P2 の descriptor に元から居る HID の keyboard / mouse / consumer も、そのままなら C に触らずに使える。
USB 機器としての実機の動作実績は、そのうち mouse (`gems/picoruby-usb-peripheral-hid-mouse`) で先に作った。
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
| 待つ | USB task を回しながら待つ。アプリが待つときはこれ | `#wait` |

subclass が実装するのは `#connected?` と `#restore_host_state` の2つだけ。
`#pump` と `#idle` は下回りで、テストではここを差し替える。

**アプリが待つときは `#idle` ではなく `#wait` を使う。** `#wait` は 1ms 刻みで
`#pump` を挟みながら待つ。

ただし **rp2040/R2P2 ではこれは keep-alive ではない**。`tud_task()` は
`usb_pump_worker()` が単独で所有し、1ms の alarm handler が毎回 pend し直すので、
アプリが素で眠っていても TinyUSB は服務される。`#pump` で稼げるのは最大 1 tick ぶんの
遅延だけ。`#wait` と `#pump` を置く理由は、長い待ちの入口を1つに決めることと、
tud_task の所有者が違う port へ移すときにそこだけを直せばよくすること。

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

**ただし R2P2 の Ctrl-C はこの ensure を通さない (issue #14)。**
`#session` の `ensure` が保証するのは tick 内で Ruby の例外が raise された
場合だけ。R2P2 shell の Ctrl-C は `picoruby-sandbox` の `Sandbox#loop` が
`Machine.poll_signal` で拾い、`Sandbox#stop` (mrubyc の `mrbc_terminate_task`)
でアプリの task をスケジューラ層から直接止める — Ruby の
raise/rescue/ensure の unwind を経由しない強制終了である
(`vendor/picoruby/mrbgems/picoruby-sandbox/mrblib/sandbox.rb`,
`src/mrubyc/sandbox.c`)。つまり `rake rp2040:upload` / `run` / `flash` /
`reboot` が `tools/pico2w/interrupt.rb` で送る Ctrl-C を含め、Ctrl-C で
アプリを止めると `restore_host_state` / `teardown` ブロックは走らず、
押しっぱなしのボタンや鳴りっぱなしの note が host に残り得る。
これは既知の制約であり、直すなら vendor/picoruby の task 強制終了の
仕組み自体 (全アプリの Ctrl-C 挙動に影響する) に手を入れる必要があるため、
本 harness の対象外としている。

## 3. 置き場所と取り込ませ方

```
gems/picoruby-usb-peripheral/            器。pure Ruby、依存なし
gems/picoruby-usb-peripheral-cdc-midi/   CDC-MIDI の結線。器 + usb-cdc-midi に依存
gems/picoruby-usb-peripheral-hid-mouse/   HID mouse の結線。器に依存 (usb-hid は firmware 側が持つ)
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
   `rakelib/vendor.rake` の `vendor:overlay` に書いてある。

   shim は tracked file を書き換えるので、**`refresh` は checkout の前に必ず戻す**。
   戻さないと、upstream がその file を変えた瞬間に
   "local changes would be overwritten" で止まる。そして overlay は
   「もう張ってある」で早戻りしない。早戻りすると HEAD が動いたあとも
   `*.upstream.rb` が前の commit のままになり、build が古い build_config を
   読み続ける — 落ちずに間違う

## 4. rake の共通インタフェース

ターゲットが増えても同じ名前で同じことが起きる、を満たす最小集合。

| タスク | 意味 | 状態 |
|---|---|---|
| `rake setup` | `vendor/picoruby` を取得し、submodule と overlay を張る | 実装済み |
| `rake refresh` | 既存の `vendor/picoruby` を取得し直す | 実装済み |
| `rake test:host` | ホストで picotest を回す。実機不要 | 実装済み |
| `rake test:examples` | example を picoruby の compiler に通す。実機不要 | 実装済み |
| `rake test` | 上の2つ。**board 無しで確かめられるのはここまで** | 実装済み |
| `rake clean` | build 生成物を捨てる (vendor は残す) | 実装済み |
| `rake <target>:setup` | そのターゲットにだけ要る重い submodule を取る | rp2040 実装済み |
| `rake <target>:build` | firmware / 実行ファイルを作る | rp2040 実装済み。ビルドは通る。compiler の submodule は固定 (§6) |
| `rake <target>:stamp` | 前回の build が今の入力に対してまだ有効か | rp2040 実装済み |
| `rake <target>:flash` | 実機へ焼く (§6) | rp2040 実装済み。**Pico 2 W 実機で BOOTSEL 押下なしに通した**。BOOTSEL は patch 無し firmware の時だけ人間 |
| `rake <target>:upload[src,dst]` | `.rb` を mrbc で `.mrb` にして board へ転送する (`HARNESS_SEND_RB=1` でソースのまま。§9) | rp2040 実装済み。Pico 2 W 実機で `.rb` → `.mrb` → 実行まで通した。esp32 も実装済み |
| `rake <target>:run[app,secs]` | 実機でアプリを走らせ、ログを取る | rp2040 実装済み。Pico 2 W 実機で通した |
| `rake <target>:reboot` | board をリブートし、shell が戻るまで待つ | rp2040 実装済み。Pico 2 W 実機で通した |
| `rake <target>:verify` | build → flash → run → **判定**。これが green で完了 | 未実装。判定が無い |

`<target>` は v1 では `rp2040` だけ。**darwin 版の USB 機器は対象外**にした。
Mac は USB 機器になる側ではなく、**相手役と開発機**として使う。

環境変数は `PICORUBY_REPO` / `PICORUBY_REF` (取得元と ref) と `SKIP_BUILD`
(`test:host` で再 build を飛ばす)。**ただし `SKIP_BUILD` は無条件の skip ではない。**
`vendor/picoruby/build/host/` は upstream 自身の rake タスク (`vendor/picoruby` の中で
直接叩く `rake test:gems:picoruby[...]` など) とも共有される場所で、そちらは自分専用の
build_config で作り直すことがある。`test:host` は毎回、今の
`vendor/picoruby` の SHA・`build_config/host-test.rb`・ハーネスの gem の内容から
stamp を計算し、`build/host/` の中身と食い違っていれば `SKIP_BUILD` が立っていても
作り直す (`rakelib/test.rake` の `ensure_host_vm_current!`)。rp2040 firmware 側の
stamp (下記) と同じ考え方。

**未実装のタスクは、黙って通ったふりをせずに落とす。** 何が無くて、代わりに
今は何をするのかを message に書く。実機まで通って初めて完了 (§5) という線引きは、
「実機の task が無い」を「実機は要らない」に読み替えられた瞬間に消える。

`verify` だけが最後まで残っているのは、**判定する相手役がまだ無い**から。
焼いて走らせるところまでは道具が揃っても、Mac 側で「送った event を受け取れたか」を
見る口が無ければ、verify は「落ちなかった」以上の
ことを言えない。それは完了の線引きとしては使えない。

`build/<target>/` の stale 化は R2P2-darwin と同じ方法で防ぐ:
`vendor/picoruby` の SHA、build_config の digest、**ハーネスの gem のうち
firmware に入る file の path と digest** (`mrbgem.rake` `mrblib/` `src/` `ports/`
`include/`。`test/` と `sig/` は build に効かないので見ない) を stamp に記録し、
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

runner は本 repo が持つ (§3 の代償)。といっても upstream の `Picotest::Runner` を
そのまま require して使えるので、持つのは「`build_config/host-test.rb` で host VM を
建てて、gem ごとに Runner を回す」処理と、`build/host/` が今の入力に対して
まだ有効かを見る stamp guard (上記 §4)。`collect_gems` の代わりは要らない。

**`gems/*/mrbgem.rake` は ASCII だけにする。** `rakelib/test.rake` の
`require_name_of` が `File.read(rake_file)` で読むが、明示 encoding が無いと
Ruby は locale (`LANG`/`LC_ALL`) 依存の default external encoding で読む。
CI やこの harness のような locale が空の環境では US-ASCII になり、**どれか1つの
gem の `mrbgem.rake` に日本語コメントが混ざっているだけで `rake test:host` 全体が
`ArgumentError: invalid byte sequence in US-ASCII` で落ちる** — 落ちた gem 自身の
テストではなく、HARNESS_GEMS 内で先に処理された無関係な gem の出力の後に出るので
原因がわかりにくい。`require_name_of` 側は `encoding: "UTF-8"` を明示して直したが、
`mrbgem.rake` は既存の慣習通り英語のみに保つ (`mrblib/` 側の日本語コメントは対象外)。

**`vendor/picoruby` の中で upstream 自身の rake タスクを直接叩くと、
`build/host/` を取り合う。** `rake test:host` は `build_config/host-test.rb`
(このharnessの gem 入り) で `vendor/picoruby/build/host/` を建てる。upstream 自身の
`rake test:gems:picoruby[<gem>]` のような、`vendor/picoruby` の中で直接動かすタスクは
**自分専用の一時 build_config で同じ `build/host/` を `rake clean` してから作り直す**
ことがあり、このharnessの gem を含まない別物の VM に静かに差し替わる
(`picoruby-dfu` の依存を検証したときに実際に踏んだ。詳細:
docs/research/picoruby-ble-dfu-survey.md)。**§4 の stamp guard がこれを自動で
検知して直すので、手で `rake test:host` を取り直す必要はない** —
`SKIP_BUILD=1` を付けたままでも、次に `rake test:host`(または `rake test`)を
叩けば「stamp mismatch」を表示してから作り直す。

### 実機層 (`rake <target>:verify`)

Pico 2 W に焼き、Mac を相手役にして、両側のログで判定する。
**実機の挙動は実機で実証するまで「動いた」と書かない。**
実機が使えない環境 (CI、web session) では、その旨を1行報告して完了宣言を保留する。

CDC-MIDI の判定材料: 送った event が受信できること、teardown 後に stuck note が残らないこと。
CDC-MIDI は 3本目の CDC (シリアル) に MIDI のバイト列を流すので、Mac からは MIDI 機器ではなく
シリアルポートとして見える (R2P2 は `CFG_TUD_MIDI 0`)。受信はそのポートを読む。

HID mouse の判定は、BOOTSEL ボタンを人が押して、board のログに press / release が対で出ることと、
Mac でクリックが効くことの目視。mouse インタフェースは app に関わらず常に列挙されているので、
列挙は判定に使えない。`examples/rp2040/bootsel_click.rb` を `rake rp2040:run` で 60 秒回し、
19 回の押下すべてで press / release が対で出てクリックが効いた。
押し続けた間は board 側で最長5秒ボタンが押されたままだったが、Mac はそれを長押しとして扱わなかった (原因は追っていない)。

## 6. 無人の焼き込みと検証 (目玉)

既存の資産は private repo `bash0C7/picoruby-ble-verify` の `pico2w/` にある
(picomodem / pmput / rsh / runapp / stages)。**これを本 repo に取り込む。**
そのうえで、いま人間に頼っている操作を減らす。

取り込み済みのもの: `tools/pico2w/` の device helper と board 上に置く script、
`firmware-patches/machine-usb-boot.patch`。
BLE 検証に依る `stages/` は持ってきていない (あちらの repo のもの)。
`rake rp2040:upload` / `run` / `reboot` / `flash` がこれらを呼ぶ。macOS の `ioreg` と `serialport` gem が要る。
本 repo から Pico 2 W 実機で `rp2040:build` / `flash` / `upload` / `run` / `reboot` を通した。

### いま人間にしか頼めない3つ

1. **patch 無し firmware が載った board の BOOTSEL 書き込み** — USB を抜き、BOOTSEL を押したまま挿し、離す。
   初回と、patch 無しの firmware を焼いた後だけ
2. **ハング復旧の USB 抜き差し**
3. **Mac の Bluetooth 許可ダイアログ** (BLE を使う検証のときだけ)

### 無人化の段取り

| 段階 | 内容 | 人間の関与 |
|---|---|---|
| G0 | `picotool load -x` で焼くだけ | 毎回 BOOTSEL |
| G1 | firmware に `Machine.usb_boot` を足し、shell から BOOTSEL へ落とす | **初回だけ** BOOTSEL |
| G2 | ハング時の電源サイクル | 未決 (機材依存) |

### G1: `Machine.usb_boot` で BOOTSEL へ落とす

R2P2 firmware は VID 0x16c0 で `CFG_TUD_VENDOR 0`、つまり reset interface を持たない。
picotool は Raspberry Pi の VID で絞るので、動作中の R2P2 を列挙すらせず、
`picotool reboot -f -u` は効かない。1200-baud touch も効かない。
BOOTSEL 中は ROM の bootloader なので picotool から普通に見える。
そこで firmware 自身に ROM の USB bootloader へ落ちる口を足す。

**firmware 側** — `firmware-patches/machine-usb-boot.patch`。picoruby-machine gem の3ファイルだけで、CMake の定義は足さない。

- `include/machine.h` に `void Machine_usb_boot(void);`
- `ports/rp2040/machine.c` で `pico/bootrom.h` を include し、`rom_reset_usb_boot(0, 0)` を呼ぶ
- `src/mruby/machine.c` に `Machine.usb_boot` を登録。`PICORB_PLATFORM_RP2` の外では `NotImplementedError`

mruby VM 側だけなので、femtoruby (mrubyc) firmware では使えない。
vendor/picoruby は upstream の木なので patch は残さない。
`rake rp2040:build` が build の間だけ `git apply` し、終わったら `git apply --reverse` で戻す。
patch の中身は firmware の stamp に入る。

**ホスト側** — `rake rp2040:flash` の手順:

1. `picotool info` が通れば既に BOOTSEL なので 2 を飛ばす (中断した run は board を BOOTSEL に置き去りにする)
2. R2P2 の port が居れば `tools/pico2w/usbboot_app.rb` を `/home/usbboot.rb` へ PicoModem で置き、shell で実行する。
   port が落ちるのは正常。`picotool info` を最大 30 秒 poll する
3. BOOTSEL に来なければ原因で分ける。timeout だけでは区別できない
   - shell が `NoMethodError` を返した → patch 無しの firmware。人手の BOOTSEL を頼んで待つ
   - 転送が失敗した / 何も返らない → wedge か転送失敗。BOOTSEL では直らないので、USB 抜き差しを促して落ちる
   - R2P2 が USB に居ない → 人手の BOOTSEL を頼んで待つ
4. `picotool load -x <uf2>`
5. `tools/pico2w/shell_ok.rb` で `$>` プロンプトが返るまで最大 90 秒待つ。起動バナーだけでは応答と見なさない

serial を開く helper は `tools/pico2w/tmo.rb` で壁時計の上限を掛けて回す。

**人間の関与** — patch 入りの firmware を最初に焼く1回だけ BOOTSEL が要る。
以後は、焼く firmware が毎回 patch を含む限り無人で回る。patch 無しを焼くと口を失う。
wedge した board (CDC は列挙されるが無音) には命令が届かないので、USB 抜き差しが要る (G2)。

**実証** — `bash0C7/picoruby-ble-verify` で Pico 2 W (RP2350) を相手に確認済み。
`Machine.usb_boot` から BOOTSEL まで約2秒。BLE の回帰を役ごとに焼き直しながら、BOOTSEL の押下ゼロで完走した。
本 repo でも、空の build dir からの `rake rp2040:build` → `rake rp2040:flash` を Pico 2 W 実機で通した。
flash は BOOTSEL 押下なしで約40秒、焼き直し後に `$>` プロンプトが返る。
Claude Code の Bash tool から、sandbox を外さずに picotool と serial に触れた。

### compiler の submodule を固定する

picoruby `4fe6e254` ("upgrade submodules") 以降の `mrbgems/mruby-compiler` は Prism の arena allocator を持ち、
compiler context ごとに 64KB を `mrb_malloc` する (`MRC_PRISM_ARENA_BLOCK`、固定値)。
起動時の context は VM の全期間生きる。heap 396KB の Pico 2 W では
`Loading /etc/init.d/r2p2...` で毎 boot 止まり、CDC は列挙されたまま open が返らなくなる。
同じ board・同じ FS で、次の3つだけを1つ前の pin に戻すと shell まで約1秒で上がる:

| submodule | 固定する pin | upstream master の pin |
|---|---|---|
| `mrbgems/picoruby-mruby/lib/mruby` | `b05a7bfd` | `fbcb3dce` |
| `mrbgems/mruby-compiler` | `db0aea5c` | `6d88acf1` |
| `mrbgems/mruby-bin-mrbc` | `fa77fbde` | `6210c2c0` |

`Rakefile` の `SUBMODULE_PINS` に持ち、`rake setup` / `refresh` が submodule を取るたびに checkout し直す。
pin は firmware の stamp に入り、stamp が変わると `build/host` (`bin/mrbc` が居る) も作り直す。
3つは同期して動くので混ぜない。

外す条件: mruby `5a7aa02a1` が `MRC_PRISM_ARENA_BLOCK` を `#ifndef` で上書き可能にした
(`picoruby/mruby-compiler2` では `beb0107` から)。picoruby の `mrbgems/mruby-compiler` の pin がそれを含んだら、
固定を外し、`build_config/rp2040-pico2_w.rb` で `MRC_PRISM_ARENA_BLOCK=4096` を define する。

### 取り込むときに落とさない知見

`picoruby-ble-verify` の SKILL.md が持っている、踏まないと分からない類のもの:

- **`/Volumes/RP2350` への `cp` は使わない。** マウント完了前に走ると
  `Device not configured` で失敗し、しかもボリュームは見えている。`picotool` は待つ
- **ポートを `/dev/cu.usbmodem*` の glob で選ばない。** USB を抜き差しするとノード名が変わり、
  ESP32 を同時に挿しているとそちらが先に並ぶ。しかも ESP32 はポートを開くとリセットされる。
  必ず USB の製品名から引く (`ioreg -w 0 -r -n "R2P2" -l | grep IOCalloutDevice`)
- **R2P2 shell は入力を Ruby として評価しない。** `Machine.reboot` と打っても何も起きない。
  スクリプトを `/home/` に置いて実行する
- **R2P2 の行エディタは接続のたびに `\e[6n` と `\e[5n` を送り、応答まで打鍵を捨てる。**
  答えないとコマンド行が黙って消え、プロンプトだけが返る。
  shell に打つ helper は `tools/pico2w/term.rb` で `\e[1;1R` と `\e[0n` を返す
- **wedge した board への blocking な serial open は macOS で返らず、SIGTERM も効かない。**
  `tmo.rb` で process group ごと SIGKILL する。生存確認は `shell_ok.rb` が fork した子で O_NONBLOCK で開く。
  `rake rp2040:upload` / `run` / `reboot` はいずれも `pmput.rb` / `runapp.rb` の呼び出しを
  `tmo.rb` 越しに束縛しており (issue #17)、wedge した board でも壁時計で失敗して返る
  (`upload` は60秒、`run` はアプリの実行秒数+30秒)。ログはその場で流れる (Open3 で溜め込まない)
- **板の serial / USB を開くものは board 単位の lock で排他する (`tools/common/device_lock.rb`)。**
  2つの session が同じ板を同時に開き、Ctrl-B の ACK が取れず出力が欠け、`shell_ok.rb` が wedge でもないのに
  DEAD を返した実例がある。lock は board の種類ごと (`rp2040` / `esp32`) に
  `~/.cache/r2p2-device-locks/<target>.lock/` を mkdir で作る (macOS に flock が無い。`owner` に `pid コマンド`)。
  - **排他にする**: 同じ board への upload / run / reboot / flash / reset / interrupt / rsh / `shell_ok.rb` /
    `boot_state.rb`。読むだけでも serial を開くなら排他 (2つの opener は互いの read を壊し、wedge に見える)
  - **同時でよい**: build、host テスト、QEMU、`ioreg` での列挙 (serial を開かない)、別の board 同士 (DualKey と Pico 2 W)
  - **粒度**: rake の `upload` / `run` / `reboot` / `flash` はコマンド単位で持つ (`run` の upload と runapp の間に
    割り込ませない)。serial を開く最下層の tool も自分で取るので、`tools/*.rb` を直接呼ぶ利用者にも効く
  - **再入**: 持ち主は自分の pid を環境変数 `R2P2_DEVICE_LOCK_HOLDER_<TARGET>` に出し、子
    (rake → `tmo.rb` → `pmput.rb`) はそれで通る。自分の親を待つデッドロックは起きない
  - **待ち・失敗**: `DEVICE_LOCK_WAIT` 秒 (既定600) 待ち、30秒ごとに持ち主の pid を表示する。超えたら持ち主を
    名指して失敗。持ち主の pid が死んでいれば奪う (`tmo.rb` が SIGKILL した場合など)。
    持ち主が生きたまま消えない時だけ `rm -r ~/.cache/r2p2-device-locks/<target>.lock`
  - **識別**: board の種類単位。同じ種類を2枚挿す運用は想定しない (要るなら port / USB serial 単位に細分する)
  - `R2P2_DEVICE_LOCK_DIR` で lock の置き場を変えられる。他の repo の script が同じ板を触るなら同じ場所を使うこと
- **shell の生存を「何か bytes が返った」で判定しない。** 起動時に固まる board も起動バナーは出す。
  `$>` プロンプトが返ったかで見る
- **R2P2 は起動時に app を自動実行する。** `/etc/init.d/r2p2` が `$HOME/app.mrb` → `$HOME/app.rb` →
  `DFU::BootManager.resolve` の順に探して load し、wifi 設定があれば `/bin/wifi_connect` も走らせる。
  FS 領域は `picotool load` を跨いで残るので、固まる app を置くと焼き直しても毎 boot 固まる。
  app が動いている間 shell は黙っていて、Ctrl-C で app が止まり `$>` が出る
  (ただし teardown は走らない — 上記「片付け (teardown) は要る」の Ctrl-C の注記参照)。
  `rake rp2040:upload` / `run` / `reboot` は prompt が返らなければ `tools/pico2w/interrupt.rb` で Ctrl-C を送る。
  `flash` / `reboot` の直後は、`tools/pico2w/boot_state.rb` が再列挙直後の CDC0 出力を読んで
  shell / app / hung を数秒で判定する (issue #16)。app が起動していると判定できた場合は
  Ctrl-C せずそのまま動かし続ける — 20 秒の盲目待ちも自動 Ctrl-C も過去の挙動。
  判定できなかった (unknown) 場合だけ、以前どおり最大20秒待ってから Ctrl-C で確かめる。
  止めた app は USB の挿し直しか reboot でまた起動する
- **firmware の CMake は `<picoruby>/bin/mrbc` で mrblib を compile する。** それを置くのはホスト VM の build なので、
  空の vendor では `rp2040:build` が先に建てる
- **マスストレージはマウントされない。** ファイル転送は PicoModem のみ
- `stackchan-picoruby` の `Deploy::Picomodem.upload` をそのまま呼んではいけない。
  RP2350 は DTR/RTS でリセットされないので起動バナー待ちでタイムアウトする

## 7. 積荷の順序

1. **器を立てる** — `gems/picoruby-usb-peripheral` の setup/tick/teardown、`rake setup` / `test` /
   `rp2040:*`、CDC-MIDI と HID mouse の結線と example が1本ずつ。
   ホストのテストと example の compile が green。HID mouse の example は Pico 2 W 実機で USB マウスとして動いた (§5)。
   **残っているのは CDC-MIDI の実機での判定。** `rp2040:verify` が無いので、まだ done ではない
2. **無人化 G1** — `rp2040:flash` から BOOTSEL の人手を外し、本 repo から Pico 2 W 実機で通した (§6)
3. **ESP32 の rake タスク** — `rake esp32:build` / `flash` / `upload` / `run` / `reboot` を M5Stack Chain DualKey 実機で通した (§9)
4. (v1 外) ESP32 向けの USB 周辺機器 gem、USB HID ゲームパッド、darwin 版の USB 機器

## 8. 未決

`rake test:host` の runner の実装量は未決ではない。upstream の
`Picotest::Runner` をそのまま require して使えるので、ハーネスが持つのは
「temp ではない build_config で host VM を建てて、gem ごとに Runner を回す」
30 行ほど。`collect_gems` の代わりは要らなかった。

- **ハング復旧 (G2) の機材。** USB hub の電源制御 (`uhubctl`) が Mac 側で効く hub があるか、
  外部リレーを足すか、firmware の watchdog で代替するか。
  `picoruby-ble-verify` での実績: app が固まる類は app 冒頭の `Watchdog.enable(8000)` と定期的な
  `Watchdog.feed` で自動復帰した。CDC ごと固まった board は USB 抜き差ししか効かず、
  Mac からは port ごとの給電制御ができなかった

## 9. ESP32 の罠

対象: M5Stack Chain DualKey（ESP32-S3、PSRAM無し）。`bash0C7/R2P2-ESP32` branch
`r2p2-esp32-btstack-integration`、VM は `mruby`。build/flash はそちらの rake
タスクへ委ねる（`rake esp32:build` / `flash`、ENV `R2P2_ESP32_REPO` で checkout
先を上書き可能）。

- **shellのCtrl-B/コマンド入力が一切届かなかった根本原因は、ESP-IDFのconsole
  routing設定だった。** Chain DualKeyにはUART0の物理配線が無く、唯一の露出
  インターフェースはESP32-S3内蔵USB Serial/JTAGペリフェリだが、`idf.py`の
  console設定はデフォルトで primary console = UART0（未接続）、USB
  Serial/JTAG = secondary（起動logの出力ミラー専用、STDIN読み取り対象外）に
  なる。この状態だと boot log や `puts` の出力は全てUSB経由で正常に見えるため
  「動いているように見えて実は入力だけが届かない」という非常に紛らわしい壊れ方
  をする。判別法: reset後、host側が端末query（`\e[6n`等）に一切応答しなくても
  `"$> "`プロンプトの描画タイミングが応答した場合と寸分違わない（実測: 常に
  reset後約22秒）→ deviceがhostからの返信を読んでいない証拠。恒久対応として
  `build_config/esp32-chain_dualkey.sdkconfig.defaults`
  （`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y`）を`rake esp32:build`が
  `vendor/R2P2-ESP32/sdkconfig.defaults`に自動追記し、古い`sdkconfig`を
  削除して再生成させる（`rakelib/esp32.rake`の`ensure_console_overlay!`）。
  この修正だけでCtrl-B ACK・PicoModemアップロード・`rsh.rb`での任意コマンド
  実行すべてが実機で確認できた
- **`"$>"`という2文字は起動時のESP-IDF boot logノイズの中に偶然出現しうる。**
  `shell_ok.rb`が過去に返していた`OK`は、この偶然一致を本物のプロンプトと
  誤認した false positive だった（resetから1秒未満、bannerより何秒も前に
  `"$>"`が出現した実例あり）。プロンプト検出は「banner文字列を見た後に
  受信したバイトの中だけ」を対象にする（`shell_ok.rb`の`post`変数）。同種の
  誤検出を避けるため、`Deploy::Picomodem`はそもそも`"$>"`文字列を探さず、
  banner後に静穏（quiet）を待ってから直接Ctrl-Bを送る設計にしてある
  （下記参照）
- **Ctrl-Bの前に`"\r\n"`で"nudge"する必要は無い。** shellの編集ループは
  Ctrl-B（0x02）を生の制御バイトとしてそのまま処理するので、`"$>"`が実際に
  出ているかを確認する必要が無い。`Deploy::Picomodem`は banner を見たら
  `QUIET_SECONDS`（0.4秒）静穏を待って直接Ctrl-Bを送るだけでよい
  （`tools/common/picomodem.rb`の`settle`）。「静穏を待たず即座に送ると
  早すぎる」という以前の記録は誤りで、真因は上記のconsole routing問題だった
- **シリアルポートを開くだけではリセットされない。** resetにはRTSパルスの
  明示的な送信が要る（`Reset.pulse`：`dtr=0` → `rts=1` → 150ms → `rts=0`）。
  「開くだけでリセットされる」という以前の記録は誤り
- **resetは`close→再open`でよい。** `Deploy::Picomodem.reset_and_reopen`は
  pulse用に一度開いて閉じ、USB CDCの再列挙（0.5〜2秒）を`REENUMERATE_TIMEOUT`
  （15秒）でpoll してから新しい接続を開く。「単一の接続を開いたままpulseする
  方が確実」という以前の記録は、false positive調査中の誤診断に基づく誤り
  だった。stackchan-picoruby（`bash0C7/stackchan-picoruby`、同じESP32-S3
  native USB Serial/JTAG系統のCoreS3向け）の`lib/deploy/picomodem.rb`が
  この形で実績があり、参照実装として復元した
- **`io.wait_readable` + `read_nonblock`は問題ない。** 「writeした後は信頼
  できない」という以前の記録は誤りで、真因は上記のconsole routing問題
  だった。`reset_and_reopen`/`read_available`/`read_exact`/`drain`は
  `wait_readable`+`read_nonblock`ベースの実装に戻してある
- **未知のshellコマンドを実行するとスタックオーバーフローで再起動することが
  ある。** `picoruby-shell`の`Shell#builtin?`が`self.respond_to?(name)`
  （private methodを含めない）で判定しているため、`_pwd`等の全builtinが
  「見つからない」と判定され外部コマンド実行パスに落ちる。そちらの
  未検出コマンド処理で深い再帰かスタック消費が起き、
  `A stack overflow in task picoruby_task`でreboot する（例:
  `rsh.rb "pwd"` → `pwd: command not found` → overflow → 自動reboot）。
  ボード自体はwatchdog的に綺麗に再起動して復帰するため実害は限定的だが、
  `rsh.rb`等でshellに任意文字列を打たせる時は要注意。firmware
  （`picoruby-shell`）側のバグでありこのharnessでは直さない
- **長時間・高頻度のresetを繰り返すとボードが無応答になることがあった。**
  この session内でTask 8の検証中に数十回resetを繰り返した後、`shell_ok.rb`
  を含む全てのアクセスが`silent`（0バイト）になり、3分待っても復帰しな
  かった。USBの物理的な抜き差しで復帰した（`ioreg`の`sessionID`変化で確認）。
  以後、console routing修正後の同日の検証では再現していない。連続テストの
  間隔を空けるか、長時間検証の前に一度リフレッシュ（抜き差し）を挟むのが安全
- **ポートを`/dev/cu.usbmodem*`のglobで選ばない。** ESP32が先に並ぶ。`tools/esp32/`
  各scriptは`ioreg -n`で製品名を見て選ぶ。Chain DualKeyの実機で確認した製品名は
  `"USB JTAG/serial debug unit"`（`"USB Product Name"`プロパティは`"USB JTAG_serial
  debug unit"`とスラッシュがアンダースコアに化けているが、`ioreg -n`が実際にマッチ
  するのはノード名側＝スラッシュ表記）。これはESP32-S3内蔵USB Serial/JTAG
  ペリフェリの既定ディスクリプタ名で、ボード固有ではなくESP32-S3であれば共通の
  はず。「R2P2」という文字列はfirmwareが自称するものではなく、この道具の名前が
  誤って製品名だと思い込んでいた設計ミス（Task 8で修正済み、`tools/esp32/*.rb`
  全ファイルと`reset.rb`）
- **heapが小さい。** PSRAM無しの約180KBで、`MRC_PRISM_ARENA_BLOCK`のデフォルト
  64KB/compiler contextのままだと起動時boot・sandbox(load時)の2つのcompiler
  contextで枯渇し`NoMemoryError` → abort → reboot loop。`R2P2-ESP32`側は
  `MRC_PRISM_ARENA_BLOCK=2048`を`components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`
  に追加済み（local commit `e5f5c090`、issue #1・#12参照）
- **書き込みはesptoolのみ。** ESP-IDFのフルインストールはこのrepoの責務にしない。
  `rake esp32:build`が内部で`idf.py`を呼ぶのは`R2P2-ESP32`側の環境の話であり、
  このharness自体はESP-IDFを直接扱わない
- **QEMU起動確認が`build`に含まれる。** `R2P2-ESP32`の`scripts/qemu_boot_check.sh`
  （デフォルト300秒、`$> `を見つけたら成功、失敗パターンでも即終了）を実機の前段
  として通す。実機無しでbuildの健全性がある程度わかる
- **QEMUのESP-IDFバージョンはCIと厳密に合わせる。** ローカルに入れたESP-IDF
  `v5.4.2`で`qemu_boot_check.sh`を走らせると、"Initializing FLASH disk as the
  root volume..."で止まったまま`$> `に到達せず、600秒待っても進まない。
  `.github/workflows/qemu.yml`は`esp_idf_version: v5.5.4`を指定しており、
  バージョン差が原因と推定（未確定）。実機検証だけを優先する場合はQEMU確認を
  一旦保留してよいが、CIのQEMU jobを信頼するにはローカルのESP-IDFをCI指定
  バージョンへ合わせる必要がある
- **gem構成によっては起動直後にCore 1のpanicでboot loopすることがある。原因は未特定
  （stack不足とは確認できていない）。** sendairk03のDualKey検証（upstream
  `picoruby/R2P2-ESP32` master + IDF v5.4.2 + `sdkconfigs/usb_console`）で、
  `ws2812`（依存で`picoruby-rmt`を引く）を含む構成にすると、
  `main_task: Returned from app_main()`の直後に`Core 1 panic'ed (StoreProhibited)`
  （PCは`vPortYieldFromInt`、core1で実行中のtaskのTCBが壊れている）がbootのたびに
  同一レジスタ値で繰り返された。`ws2812`を外すか、envで
  `PICORB_TASK_STACK_SIZE=16384`（既定8192）を渡すと消えた（QEMUと実機の両方で
  1変数ずつ確認）が、これは緩和策として効いた事実に過ぎない。同じstack 8192のまま
  panicしない最終構成もあり（`rake esp32:qemu_check`でPASS）、panicはgem構成と
  メモリ配置に依存して出たり出なかったりする。btstack branchのgem構成で同じことが
  起きるかは未確認
- **QEMU確認はboot loopの検出器として使える。** `scripts/qemu_boot_check.sh mruby`
  はローカルIDF v5.4.2では`$> `に届かずtimeoutするが（上記）、panicの有無は
  見分けられる。実機を焼く前に、`QEMU_BOOT_TIMEOUT=60`でgem構成を1変数ずつ変えて
  切り分けられる。`rake esp32:qemu_check`（IDFのexport済みが前提、
  `QEMU_BOOT_TIMEOUT`既定60）がログで判定する: `Guru Meditation`/`Rebooting...`
  があればFAIL、なくて`main_task: Returned from app_main()`が出ていればPASS
  （`$> `未到達は既知としてその旨を表示）、それも無ければFAIL。QEMUで実測済み: 通常構成はPASS、
  `PICORB_TASK_STACK_SIZE=1024`にするとCore 1が`LoadProhibited`でpanicしFAIL（exit 1、該当行を表示）
- **`upload` / `run` は既定で mrbc により `.mrb` にコンパイルして送る。** 実機に `.rb` を
  送って shell から走らせると、板上で prism がコンパイルするため heap を食い、DualKey
  （ESP32-S3、mruby VM）で1.4〜2.3KBの小さなscriptでも`NoMemoryError`で落ちた
  （1行のscriptは通り、閾値はgemの量とheap設定で動く）。同じscriptをhostのmrbcで`.mrb`
  （1003バイト）にして送ると完走し、結果も一致した。`.rb`を渡すと`build/mrb/<name>.mrb`を作り、
  送り先も`.mrb`にする（`/home/app.rb`を指定しても`/home/app.mrb`。`/etc/init.d/r2p2`は
  `app.mrb`を先に見る）。`.mrb`を渡せばそのまま送る。`HARNESS_SEND_RB=1`で`.rb`を
  ソースのまま送る。mrbcが無い/compileが失敗した時は`.rb`に戻さず、理由を出して落ちる。
  使うmrbcは firmware を build した picoruby のもの（VMの版が板と合う必要がある）: ESP32は
  `R2P2-ESP32/components/picoruby-esp32/picoruby/build/host/bin/mrbc`、Pico 2 Wは
  `vendor/picoruby/bin/mrbc`。`MRBC=`で差し替えられる。DualKeyでの実測はconcurrency-r1-ff
  session（`.mrb`を直接送る別scriptでの実測）。Pico 2 Wは`rake rp2040:run`で`.rb`→`.mrb`→実行まで実機で通した。
  `rake esp32:run`もDualKey実機で`.rb`→`.mrb`→転送→実行まで通した（出力`hello from mrb 3`）。
  板に戻らない`/home/app.mrb`が残っている場合の復旧は[faq.md](faq.md)

## 10. FPGA × mruby ネイティブ CPU

mruby のバイトコード (`.mrb`、RITE0400) を、ソフト VM ではなくハードウェアのデコーダと ALU で
1命令ずつ実行する CPU を FPGA に作る (issue #4)。実機 (PERIDOT-Air) に焼く前に、シミュレータで
万全に動かす。HDL とテストベンチは SystemVerilog、道具は Ruby (rake)。Python は使わない。
設計: [シミュレーション環境](superpowers/specs/2026-09-26-fpga-sim-env-design.md)、
[CPU コアと道具立て](superpowers/specs/2026-09-26-fpga-mruby-core-design.md)

```
fpga/corpus/*.rb --mrbc--> .mrb --mrb2rom.rb (PicoRuby)--> ROM (48bit/命令, $readmemh)
                                                      |                         |
                          tools/fpga/ref_vm.rb (参照) <-+-> fpga/rtl/mrb_core.sv (コア)
                                     \______ rake fpga:check が I/O とトレースを突き合わせる ______/
```

### タスク

| タスク | 意味 |
|---|---|
| `rake fpga:setup` | 足りないシミュレータを入れる。macOS は `brew install verilator icarus-verilog surfer`、Linux は `apt-get install -y verilator iverilog` (root でなければ sudo) |
| `rake fpga:doctor` | verilator / iverilog / vvp / surfer の有無と版。必須が欠けていれば落ちる |
| `rake fpga:test` | 下の `test:fpga` + `fpga:tb` + `fpga:check` + `fpga:emu:check` + ファズ 300 本。CI の `fpga` job が回す |
| `rake test:fpga` | `tools/fpga/*_test.rb` (minitest)。シミュレータ不要。picoruby が要るものは無ければ skip。CI の `host` job でも回す |
| `rake fpga:tb` | `fpga/tb/*_tb.sv` を全部、Verilator と Icarus の両方で回す |
| `rake fpga:sim[tb]` / `fpga:sim:icarus[tb]` | 1本だけ。波形は `build/fpga/<tb>.fst` / `<tb>.icarus.fst` |
| `rake fpga:tb:ref` | `mrb_core_tb` の各ケースの ROM (`+dumprom`) を参照インタプリタで走らせ、終わり方とレジスタを出す。ケースの期待値は先にこれで確かめてから書く |
| `rake fpga:check` | `fpga/corpus/*.hex` を参照インタプリタとシミュレーションの両方で走らせて突き合わせる |
| `rake fpga:fuzz[count,seed]` | ランダムな ROM を参照とシミュレーションで走らせ、トレースを全行比べる (差分ファズ) |
| `rake fpga:gap[verbose]` | 実在の PicoRuby プログラム (gem の example、`examples/`、コーパス) を変換器とコアに通し、範囲内の何本が動くか、残りを止めている理由 (全部) を多い順に出す。一覧は `build/fpga/gap.txt`。進め方の指標 ([計画](superpowers/plans/2026-09-26-fpga-full-picoruby.md)) |
| `rake fpga:emu[src,ms,ce_div,mhz]` | PERIDOT-Air のボードエミュレーター。実機の top をクロック `mhz` (既定 125MHz) で回し、LED とボタンの変化を実時間 (秒) で表示し、参照インタプリタと突き合わせる |
| `rake fpga:emu:check` | コーパス全部をエミュレーターで 600ms 回し、LED の変化を参照と突き合わせる |
| `rake fpga:rom[src]` | `.rb` / `.mrb` を PicoRuby の変換器で ROM イメージ (`build/fpga/rom/<name>.hex` と一覧 `.lst`) にする |
| `rake fpga:run[src,max]` | 1本をシミュレーションで走らせ、I/O を表示する。トレースと波形を `build/fpga/rom/` に残す |
| `rake fpga:corpus` / `fpga:corpus:check` | コーパスの `.mrb` `.dump` `.hex` `.lst` と `docs/fpga-opcodes.md` を mrbc と PicoRuby の変換器で作り直す / 最新かを見る |
| `rake fpga:gen` | `fpga/rtl/mrb_pkg.sv` を `tools/fpga/isa.rb` と `io_map.rb` から作り直す |
| `rake fpga:build[src,ce_div]` | PERIDOT-Air 向けに Quartus で合成し、書き込み用 `.svf` を作る (下記)。**実機では未確認** |
| `rake fpga:flash` | 最後の `fpga:build` を openFPGALoader で SRAM に書く。**実機では未確認** |

`fpga:test` は `vendor/picoruby` 無しで回る (コーパスの `.mrb` と ROM を commit してあるため)。`rake test` には含まれない。
picoruby (host VM) が要るのは変換器を走らせる `fpga:rom` / `fpga:run` / `fpga:build` / `fpga:corpus`、
mrbc が要るのはそれらに `.rb` を直接渡した時と `fpga:corpus`。どちらも `rake setup` と `rake test:host` で出来る
(`PICORUBY=` / `MRBC=` で差し替えられる)。

### 置き場所

- `fpga/rtl/**/*.sv`: 回路。`*_pkg.sv` を先に、全部を毎回コンパイルに渡す。`fpga/rtl/boards/` は実機の top
- `fpga/tb/<name>_tb.sv`: 自己チェック型テストベンチ。top module 名を file 名と揃える
- `fpga/sim/`: プログラムを走らせるテストベンチ (`mrb_run_tb.sv`)。合否は rake 側が出すので `fpga:tb` の対象外
- `fpga/corpus/`: 対象の Ruby プログラムと、その `.mrb` / `.dump` / ROM (`.hex` `.lst`) / 入力の刺激 `.stim`
- `fpga/boards/peridot_air/`: Quartus の設定 (`.qsf` `.sdc`)
- `tools/fpga/`: ROM 変換器 (PicoRuby: `isa.rb` `io_map.rb` `rite.rb` `rom.rb` `mrb2rom.rb`) と、
  参照インタプリタ・突き合わせ・Quartus プロジェクト生成 (CRuby)

各 `.sv` に `` `timescale 1ns / 1ps `` を書く (1つでも書くと、書いていない module を Verilator が
`TIMESCALEMOD` で落とす)。

### テストベンチの合否

テストベンチは合格なら最後に `PASS <tb名>` を出して `$finish`、食い違えば `$fatal`。
rake は exit status が 0 **かつ** `PASS <tb名>` 行がある時だけ合格にする。
`+dump=<path>` が渡された時だけ `$dumpfile` / `$dumpvars` で波形を書く (`fpga/tb/counter8_tb.sv` が雛形)。
Verilator の `$fatal` は abort() なので、rake には exit code ではなく signal 6 として返る。

**Verilator だけではリセット漏れを見逃す。** Verilator は2値なので、リセットされない register は 0 から
始まり、たまたま期待値と合う。counter8 のリセット代入を消すと、Icarus は最初の check で
`count is X/Z` で落ちたが、Verilator は数え終わった後の非同期リセットの check まで通った。
テストベンチはリセット直後に `$isunknown` を見る。`fpga:tb` は両方で回す。

**Verilator の -Wall。** warning は error になる。RTL は -Wall のまま通す。テストベンチは file の先頭で
`WIDTH` `BLKSEQ` など、テストベンチの書き方で出るものだけ `/* verilator lint_off ... */` で切る
(`lint_on` を後に書くと先頭の `lint_off` も戻るので、書かない)。`mrb_pkg.sv` は `UNUSEDPARAM` を切っている。

**Icarus の癖。** `always_comb` の中の定数の部分選択に `sorry: constant selects ...` を出すが、
感度が広がるだけで結果は変わらない。型付きの `parameter string` は上位から渡せないので、
`ROM_FILE` は型を付けない。可変 index の packed 配列をさらに部分選択すると内部エラーで落ちる
(`out_val[p][33:32]` のような形は一度変数に受ける)。**`always_comb` の中で2回書いてから読む変数と、`if` の条件の関数の
呼び出し (`is_ref(ra)` など)、`if` の中でヒープを2段たどって読む三項演算子 (APOST の値) は、Icarus が時刻を進めなくなる
原因になった** (Verilator は通る)。前もって `assign` で wire にする。rake はコンパイラの出力を
`build/fpga/**/build.log` に落とし、失敗した時だけ表示する。

**テストベンチから ROM を書くのは `#1` 待ってから。** `mrb_soc` の `initial` が ROM を全 bit 1 で埋めるので、
同じ時刻 0 にテストベンチが書くと、どちらが後かはシミュレータ次第になる。

### 対応命令と値の表現 (#6)

コーパス駆動で決めた。`fpga/corpus/*.rb` とプレリュード (`fpga/prelude/*.rb`) の `mrbc -v` に出る命令と、同じ族で回路が
ほぼ増えないもの (`LOADI_n` 全部、比較4種、`ADDI`/`SUBI`、`JMPIF`/`JMPNIL`) をコアが実行し
(`tools/fpga/isa.rb` の `SUPPORTED`)、`SENDB` `SSENDB` `LAMBDA` `MODULE` `LOADSELF` `RETSELF` `RETTRUE` `RETFALSE` は
変換器がほかの命令にする (`LOWERED`)。FPGA だけの命令は `TABLE` (ROM の先頭、下の「メソッド表と呼び出し」) と
`HTABLE` (例外の表、下の「例外 (P4)」)。
多重代入 (`a, b = ary`) の `AREF` は、配列なら R[b][c]、配列でなければ c = 0 の時だけ R[b] 自身、ほかは nil。
一覧と出現回数は [fpga-opcodes.md](fpga-opcodes.md) (`rake fpga:corpus` が生成)。

- **整数は 32bit で折り返す。** R2P2 は `MRB_INT64` だが、6k LE では 32bit にする。範囲外は仕様外
  (mruby なら 64bit / Bignum になる所で、コアは黙って折り返す)
- **値 = 4bit のタグ + 32bit。** タグは nil=0 / false=1 / true=2 / Integer=3 / Symbol=4 (番号) / Class=5 (クラスの番号) /
  Object=6 (ヒープの語アドレス) (7 と 8 はヒープの中だけ: GC の転送先と、オブジェクトの見出し。9〜15 は空き)。
  偽は nil と false だけ (0 は真)。Array と Proc は Object で、クラスは見出しの上位 16bit (下の「配列とヒープ」)。
  シンボルの番号は変換器がプログラム全体で振り (`LOADSYM`)、名前の表は ROM の一覧 (`.lst`) の最後に出る
- **演算の命令は mruby と同じく、型が合わなければメソッドを送る。** `ADD` `SUB` `MUL` `DIV` `LT` `LE` `GT` `GE` は
  整数同士でなければ `+` `-` ... を、`ADDI` / `SUBI` は整数でなければ R[a+1] = b にして `+` / `-` を、
  `GETIDX` / `GETIDX0` / `SETIDX` は配列でなければ `[]` / `[]=` を、`EQ` はどちらかがヒープのオブジェクトなら `==` を送る
  (メソッド表を引き、無ければ NoMethodError でエラー)。`EQ` はそれ以外なら値で比べる (Integer・Symbol・Class は値、
  nil / true / false は型)。`ADDILV` / `SUBILV` の落ち先は mruby では C からの呼び出しなので、コアはエラーにする
- **`STOP` と、一番外側の `RETURN` / `RETNIL` で止まる。** 未対応の opcode、レジスタ番号の範囲外、ROM の外へ出た時もエラーで止まる
- **`*` `/` `%` は Ruby と同じく floor 側に丸める** (`-7 / 2 = -4`、`-7 % 3 = 2`)。0 で割るとエラー。
  `INT_MIN / -1` は折り返して `INT_MIN`。シフトは 32 以上ずらすと 0 (右は符号)、負の量は逆向き
- **定数 (`GETCONST` `SETCONST`) は 64 個まで (一般のグローバル変数とクラス変数も同じ表)。** 名前は変換時に字句の入れ子
  (Ruby の cref: `module A; class B` の中なら `A::B::X`、`A::X`、`X`。`class A::B` の中なら `A::B::X`、`X`) の順に探して番号にする。
  クラスの名前なら `CLASS` (クラスの即値) にする。代入前に読むとエラー。親クラスの定数は探さない
- **`A::X` (`GETMCNST` / `SETMCNST`) と `class A::B`** は、入れ物を直前の `GETCONST` / `GETMCNST` の連なりから静的に解く。
  入れ物が知っているクラス・モジュールでない (`GPIO::OUT` のようにデバイスのクラスがまだ無い時も)、`A::X` がどこでも
  代入されていなければ変換時に止める。空の本体のクラス (`class E < StandardError; end`、mruby は `EXEC` を出さない) も通す
- **配列は `[...]`、`a[i]` (負の添字も)、`a[i] = v` (伸ばす)。** `GETIDX` は配列を整数で引く時だけその場で読み、ほか (Range で切り出す
  など) は `[]` を送る。文字列は下の「文字列と出力 (P2)」、Hash・Range は「Hash と Range (P3)」
- **引数は必須・省略可能・残り (`*r`)・後ろの必須・`&blk`・キーワード (`k:`、`**opts`)、呼び出しの splat (`f(*a)`、`f(**h)`)。**
  下の「引数 (P1d)」
- **pool の Float と 32bit に収まらない整数は変換時に止める**
- **compiler の版は `SUBMODULE_PINS` の mruby-compiler に固定。** 版が変わると命令が変わる (`ADDI`→`ADDILV` のように)。
  `rake fpga:corpus:check` (`test:fpga` の中) が、コーパスの生成物と今の mrbc の出力が一致するかを見る

### メソッド表と呼び出し

**メソッドは実行時に引く (動的な呼び出し)。** 変換器がクラスの定義 (`class` / `module` / `def` / `def self.`) を読み、
(クラスの番号, シンボルの番号) → 飛び先 の表を ROM の後ろに置く。コアは受け手のクラスで表を引き、無ければ親クラスへ進む。

- **クラスの番号。** 組み込みは固定 (`CLASSES`: Object 1、NilClass 2、TrueClass 3、FalseClass 4、Integer 5、Symbol 6、
  Array 7、Proc 8、Class 9、Module 10 ...)、プログラムのクラスとモジュールは 32 から。クラスメソッド (`def self.x`) は
  メタクラス (番号 | 0x8000) のメソッド。Class の即値の受け手はそのメタクラスで引く
- **表の1語 = {クラス 16bit, シンボル 16bit, 飛び先 16bit}。** 飛び先の上位 2bit が種類: 0 = メソッドの先頭 pc、
  1 = primitive (回路が持つメソッド、`PRIMS`)、2 = インスタンス変数を読む、3 = 書く (下の「オブジェクト」)。(クラス, `SUPER_SYM` = 0xFFFF) の飛び先は親クラスの番号
  (メタクラスは親のメタクラスへ、Object のメタクラスは Class へ)。空きは全 bit 1
- **開番地法のハッシュ表。** 位置は (クラス × 5 + シンボル) & (大きさ − 1) から1語ずつ。大きさは項目の2倍以上の2の冪 (16 以上)。
  コアは 1 cycle に1語比べる (S_LOOKUP / S_PROBE)。見つからなければ親の輪を引き、32 段で諦める (表が壊れていても止まる)
- **`TABLE` (pc 0)。** a = 表の大きさの log2、b = 表の先頭の語アドレス、c = シンボル表の先頭。実行するまではどの探索も見つからない
- **呼び出し (`SEND` / `SEND0` / `SSEND` / `SSEND0`)。** b = シンボルの番号、c = 引数の数 | ブロックを渡す印 << 7。
  `SSEND` は R0 (self) を R[a] に写してから引く。メソッドなら新しいフレーム (底は bp + a、R0 = 受け手、
  R[1..引数の数] = 引数、その次がブロックの枠。ブロックを渡さなければ nil) を作って飛び、primitive なら S_PRIM でその場で実行する。
  引数の数 15 は splat (R[1] が引数の配列、ブロックの枠は R[2])。primitive は `new` と Proc#`call` だけが受ける。
  呼び出しの深さは 16 まで
- **メソッドとブロックの先頭の `ENTER`** が引数を調べて並べ (下の「引数 (P1d)」)、nregs までを nil で埋める (S_CLEAR)。
  クラスの本体は mruby が `ENTER` を出さないので、変換器が先頭に足す
- **クラスの定義は実行時にも本体を走らせる。** `CLASS` は R[a] = クラスの即値、`EXEC` はそれを self にして本体を呼ぶ
  (本体の中の定数の代入のため)。`TDEF` / `SDEF` は実行時には R[a] = :名前 だけ (表は変換時に作った)。
  同じ名前を2回 def したら後の定義が勝つ (静的に決めるので、2回目の def より前の呼び出しも後の定義を呼ぶ)
- **変換時に止めるもの:** 定数でない親クラス、クラスの本体の外の `def self.x`、
  クラスの本体の中の `extend` `prepend` `define_method` `alias_method` とインスタンス変数、ブロックの中の `super`
- **primitive** (`PRIMS`): Integer の `+ - * / < <= > >= ==` `%` `-@` `<<` `>>` `&` `|` `^` `~` `abs` `zero?` `even?` `odd?`、
  Object の `!` `==` (同じものか) `class` `sleep_ms` `sleep` `lambda` `is_a?` `kind_of?` `respond_to?`、Class の `new`、Array の `size` `length` `empty?` `first` `last` `pop`
  `push` `<<` `[]` `[]=`、Proc の `call`。受け手の型が違えばエラー (表が壊れていても同じ結果になるように)。
  プログラムのどこにも名前が出てこない primitive は表に入れない

### オブジェクト (P1c)

- **オブジェクトは `[見出し (クラス, n)] [インスタンス変数 × n]`。** `Class#new` (primitive) が (クラス, `NIVARS_SYM` = 0xFFFE)
  を親を辿らずに引いて n を得て (無ければ 0)、確保して nil で埋め、R[a] に置いてから `initialize` を送る。
  `initialize` のフレームは印 (ctor) を持ち、戻り値で R[a] を上書きしない。作れるのは Object とプログラムのクラスだけ
- **インスタンス変数の並びは変換時に決める。** 親の並びの後ろに、そのクラス (と include した module) で初めて出てくる名前を足す。
  (クラス, @名前) の行の飛び先は種類 2 + 何番目か。行はそのクラスで増えた分だけ置き、親の分は親を辿って引く。
  `GETIV` / `SETIV` は b = @名前のシンボル番号で、self のクラスから引く。`GETIV` は見つからなければ nil、
  `SETIV` は見つからなければエラー (変換器が全部の代入に行を作るので、表が壊れた時だけ)
- **`attr_reader` / `attr_writer` / `attr_accessor`** は (クラス, :x) → 種類 2、(クラス, :x=) → 種類 3 の行にする
  (メソッドを呼ばずに、見つけたその場で読み書きする)。本体の中の呼び出しは `LOADNIL` になる
- **`super`** は、今のメソッドが見つかったクラス (フレームが持つ mcls) の親から、今のメソッドの名前 (b) を引く。
  受け手は self、ブロックの枠はそのまま渡す (c = 引数の数 | 0x80)
- **`include`** は、クラスとその親の間に module の写し (iclass、番号は別に振る) を挟む。module のメソッドは iclass から見つかる
- **`is_a?` / `kind_of?` / `===`** は (`ISA_BIT` 0x4000 | クラス, 祖先のクラス) の行があるかを親を辿らずに1回で引く。
  行は祖先 (自分、親、include した module、Object) の分だけ、プログラムにこれらの名前が出てくる時だけ置く。
  `respond_to?` は普通の探索 (親を辿る) で見つかるか
- **クラス変数 (`@@x`)** は、代入するクラスのうち一番上の祖先を持ち主にした定数 (`Foo::@@x`) にする
- **一番外の self は Object のインスタンス (main)。** 変換器が一番外の irep の先頭に `CLASS R0 Object` と `SEND0 R0 :new` を足す

### 引数 (P1d)

mruby 3.3 の `OP_ENTER` と同じ並べ方を、参照インタプリタ (`enter`) と RTL (S_ENLATCH .. S_ENFIN) が同じ順にする。

- **`ENTER` の語。** a = 必須 m1、b = nregs、c = 省略可能 o | 残り r << 5 | 後ろの必須 m2 << 6。len = m1 + o + r + m2。
  後ろに省略可能な引数の既定値へ飛ぶ `JMP` の表 (o + 1 語) が続き、渡された省略可能な引数の数だけ飛ばす
- **引数は R[1..argc]、argc = 15 なら R[1] の配列の中身。** メソッドと lambda (今の Proc が無いか lambda) は、
  数が m1 + m2 より少ないか、残りが無くて m1 + o + m2 より多ければエラー。proc は調べず、引数が1つの配列で len > 1 なら展開する
- **並べ終えた形:** R[1..m1+o] 前、R[m1+o+1] 残りの配列、その後ろに m2、R[len+1] ブロック、nregs まで nil。
  足りない所は nil (後ろの必須は、前を埋めてから余った分)
- **順序:** 残りの配列を確保して写す (GC が走ってよい。まだ何も動かしていない) → ブロックと配列の中身の位置を覚える →
  後ろの必須を動かす (レジスタの上へ動く時は後ろから) → 前 → 残りの配列とブロックを置く → nil で埋める。
  書き込みはトレースに出さない。必須だけで数が合う時は、前と同じく埋めるだけ (S_CLEAR)
- **配列の展開の命令。** `ARYCAT` (R[a] = splat(R[a]) + splat(R[a+1])。splat は、配列は中身、nil は空、Proc と即値は1要素、
  ほかのオブジェクトは to_a を持つかもしれないのでエラー)、`ARYPUSH` (R[a] + [R[a+1..a+b]])、
  `APOST` (a, *b, c = v: R[a] = 真ん中の配列、R[a+1..a+c] = 後ろ。配列でなければ [v])、
  `ARGARY` (引数なしの super: R[a] = 今のメソッドの引数の配列、R[a+1] = ブロック。b は mruby のまま)。
  どれも新しい配列を作る (mruby は ARYCAT / ARYPUSH で R[a] を伸ばすが、R[a] は同じ式の中で作った配列なので違いは見えない)
- **キーワード引数 (P3、PicoRuby の vm.c の `vm_op_enter` / OP_SEND と同じ意味):** 呼ぶ側は nk 組を Hash にしてから、印 KW (c の bit 8)
  付きで呼ぶ (変換器が `ARRAY k 2nk` と作業用レジスタでの `__to_hash` に下げる。`**h` は空なら印なし)。印付きの呼び出しは
  R[window(argc)] に Hash を持ち、ブロックの枠はその次。フレームは印を持つ (`new` は initialize へ、Proc#call はブロックへ渡す。
  ほかの primitive はエラー)。`ENTER` の c の bit 11 (kd: キーワードか `**opts` を受ける) が立っていれば R[len+1] = Hash
  (渡されなければ回路が空の Hash を作る。Hash の形 `@keys @vals @default @default_proc` は変換器が確かめる)、ブロックは R[len+2]。
  kd でなければ Hash を最後の引数として数える (引数が 14 個以上なら止める)。`KARG` / `KEY_P` / `KEYEND` は、フレームの上の
  作業用レジスタ (nregs) で `R[len+1].__karg(:k)` (Hash から消す) / `key?(:k)` / `__keyend` を呼ぶ形に下げる
- **変換時に止めるもの:** ブロックの外のフレームの `ARGARY`、キーワード引数を受けるメソッドの引数なしの super (`ARGARY` の kd)

### 文字列と出力 (P2)

- **String は Array と同じ形** (`[見出し String] [長さ] [中身への参照]`、中身は `[見出し] [バイト × 容量]`)、**1語に1バイト**
  (Integer 0..255)。確保・伸長・写し・GC は配列と同じ回路を使う
- **`STRING a b c`** は R[a] = ROM のデータ (b から、長さ c) の新しい String。コアは確保してから ROM を読んで写す
  (1バイト 2 cycle、S_SROM / S_SBYTE)。同じ中身の pool の文字列はデータを1つにする
- **`STRCAT a`** は変換器が `SEND a+1 :to_s` と `SEND a :<< 1` に下げる (式展開は必ず新しい `STRING` から始まる)。
  **`LOADL`** は 32bit に収まる整数なら `LOADI32`。**`JMPUW`** (while の中の break) は catch handler が無い irep では `JMP`
- **String の primitive** (受け手が String でなければエラー、範囲の外もエラー): `bytesize`、`getbyte` (Array#[] と同じ意味)、
  `__aset(i, b)` (0 <= i < 長さ、b は 0..255)、`__push(b)` (伸ばす)、`__slice(i, n)` (新しい String)。
  `Symbol#to_s` (SYMSTR) はシンボル表を読んで作る。`Module#__name_sym` は変換器がメソッド表に置いた
  (クラス, `NAME_SYM` = 0xFFFD) → 名前のシンボルを親をたどらずに引く (`Module#name` はその `to_s`)
- **ほかの String のメソッドと表示はプレリュード** (`fpga/prelude/string.rb`)。文字は UTF-8 として数える
  (`size` `[]` `reverse` `chars` `index`)。`upcase` などは ASCII だけで、ほかの文字があれば止める。
  `inspect` は CRuby と同じ形 (制御文字は `\uXXXX`)。`format` / `%` は `%d %i %s %p %x %X %o %b %c %%` とフラグ `- 0 + 空白`、幅
  (精度と Float は止める)。`Object#inspect` は `#<クラス名>` (CRuby はアドレスとインスタンス変数を出すので合わない)
- **出力は console ポート** (`$CONSOLE`、出力ポート 3) に1バイトずつ書く (`puts` `print` `p` はプレリュード)。
  トレースは O 行のまま。参照との突き合わせ (`ref_vm_test.rb`) は、止まるプログラムの console のバイト列を
  CRuby の標準出力と picoruby の出力 (最後の `p` の行を除く) の両方と比べる。PERIDOT-Air の top には console のピンがまだ無い
  (UART の TX は P5)

### Hash と Range (P3)

- **Hash・Range・Exception はプレリュードの Ruby のクラス** (組み込みの番号 12 / 13 / 15 のまま)。`new` でき、インスタンス変数を持てる
  (`FpgaIsa.instantiable?`、RTL の `inst_ok`)。Hash は `@keys` `@vals` の2つの配列で挿入順を保ち、キーは `eql?` で線形に探す
  (`Object#eql?` は同じものか (primitive `equal?`)、Integer・String・Array は値で比べる)。Range は `@first` `@last` `@excl`
- **作る命令は変換器が下げる:** `HASH a n` → `ARRAY a 2n` + `SEND a :__to_hash`、`HASHADD a n` → `ARRAY a+1 2n` + `SEND a :__add_pairs 1`、
  `HASHCAT a` → `SEND a :__merge! 1`、`RANGE_INC` / `RANGE_EXC a` → `SEND a :__range_inc` / `:__range_exc 1`
- **`Enumerable`** (each を使うメソッド) を Array・Hash・Range が include する。Hash の `each` は `[key, value]` を1つ yield する
  (proc が展開するので `|k, v|` で受けられる)。`Array#[]` は `(i)` だけが primitive (`__aget`)、`(i, n)` と `(range)` はプレリュード
- **`Hash#inspect` は PicoRuby の形** (`{"a" => 1, b: 2}`、Symbol のキーはいつも `名前: `)。CRuby 3.3 の形とは違うので、
  参照の突き合わせは CRuby に同じ形の `Hash#inspect` を入れてから走らせる (`FpgaOracle::HASH_INSPECT`)
- **`case` / `when`** は `===` を送るだけ。`Range#===` / `include?` は CRuby の `cover?` と同じく `<=>` で比べ、比べられなければ偽
- **プレリュードの使わないメソッドは ROM に置かない。** 変換器が、一番外から生きているコード (ブロック、クラスの本体) と、
  名前が使われる (送る、`LOADSYM`、`super`、下げた命令が送る) メソッドを、増えなくなるまでたどる (`live_ireps`)。
  置かないメソッドの中の未対応の命令は止めない

### 例外 (P4)

PicoRuby の vm.c (mruby 3.x) の `L_RAISE` / `catch_handler_find` / `UNWIND_ENSURE` / `THROW_TAGGED_BREAK` /
`OP_EXCEPT` / `OP_RESCUE` / `OP_RAISEIF` / `OP_JMPUW` と同じ意味にした。

- **例外の表。** 変換器が全部の irep の catch handler (種類 rescue / ensure、begin、end、target。iseq のバイト位置) を pc (語) に
  直し、シンボル表とメソッド表の間に置く。1語 = {種類 << 15 | 飛び先 (op と a の 16bit), begin (b), end (c)}、
  begin <= pc < end の命令が覆われる (mruby の「次の命令の位置で begin < pc <= end」と同じ)。並びは irep ごとに .mrb の後ろから
  (vm.c が探す順)。irep の範囲は重ならないので、表を先頭から探して最初に覆うものが vm.c と同じになる。
  表の位置と数は `HTABLE` (FPGA だけの命令、b = 先頭、c = 数) で、表がある時だけ pc 1 に置く
- **投げる。** `raise` はプレリュード (`Object#raise`、下) が例外のオブジェクトを作り、primitive `__raise` で投げる。
  コアは例外をレジスタ `exc` に置き、今のフレームの pc (呼び出し元のフレームは戻り先 − 1 = 呼び出した命令) を覆う
  rescue か ensure を表から探す。無ければフレームを畳んで (env はレジスタを写す) 呼び出し元で探す。見つかれば target へ。
  一番外まで無ければエラーで止まる (E 行は投げた命令)
- **`EXCEPT a`** は R[a] = exc (exc は nil に)、**`RESCUE a b`** は R[b] = R[a].is_a?(R[b]) (`is_a?` と同じ表の行を1回引く。
  R[b] がクラスでなければエラー。`RESCUE` があれば変換器が行を置く)、**`RAISEIF a`** は R[a] が nil なら何もせず、
  巻き戻しの塊 (下) なら続きを、ほかは例外として投げ直す
- **ensure を通り抜ける `return` / `break` / `next` / `JMPUW` (while の中の break、retry)。** mruby の RBreak と同じく、
  抜ける所 (今のフレームと、畳むフレームの呼び出しの位置) が ensure に覆われていれば、巻き戻しの塊
  `[HDR(BRK, 2)] [種類 << 16 | 行き先] [値]` (クラス 0x7FF2、ヒープの中だけのもの) を作って exc に置き、ensure へ飛ぶ。
  ensure の最後の `RAISEIF` がその塊を受け、そこから同じ巻き戻しを続ける。種類は JUMP (`JMPUW`: 同じフレームの pc へ。
  行き先がその ensure の範囲の中ならただ飛ぶ)、RET (底が行き先のフレームから戻る: `return`、lambda の中の `break`、
  ブロックの中の `return`)、BRK (Proc を作ったフレームへの `break`)、BRK0 (iterator に直接渡したブロックの `break`)。
  `JMPUW` は ensure に覆われていなければ変換器がただの `JMP` にする
- **コアは1つの状態機械で巻き戻す** (S_XSTART → S_XSCAN → S_XHIT / S_XMISS → S_XPOP、塊を作る S_BRKW)。
  表を 1 cycle に1語比べる。例外の表が無いプログラムの `return` は今までどおり表を引かない。
  `exc` と運ぶ値 `xval` は GC の根 (cp、env の後、この順)
- **例外のクラスはプレリュード** (`fpga/prelude/exceptions.rb`)。Exception は組み込みの 15、StandardError RuntimeError
  ArgumentError TypeError NameError NoMethodError ZeroDivisionError IndexError KeyError StopIteration RangeError
  LocalJumpError FrozenError ScriptError NotImplementedError は Ruby のクラス。`message` / `to_s` はメッセージが無ければ
  クラスの名前。**`inspect` は PicoRuby の形** (メッセージが無いか空ならクラスの名前だけ、あれば `#<クラス: メッセージ>`)。
  CRuby 3.3 は `#<TypeError: TypeError>` と出すので、参照の突き合わせは CRuby に同じ形の `Exception#inspect` を入れる
  (`FpgaOracle::EXC_INSPECT`)。`Exception.new(nil).message` は CRuby と同じくクラスの名前 (PicoRuby は `""`)
- **`raise`** は `raise` (今 rescue している `$!` を投げ直す。無ければ RuntimeError "unhandled exception")、`raise "msg"`、
  `raise Cls`、`raise Cls, "msg"`、`raise obj`。3つ目の引数 (backtrace) は止める。`$!` は一般のグローバル変数
  (mrbc が rescue の出入りで保存・復元する)。`backtrace` `full_message` は無い (呼べばエラー)
- **使われないクラスはメソッド表に行を置かない** (`live_classes`)。組み込みと、生きているコードで定数として参照される
  クラス (親クラス・入れ物・`include` の引数としての参照は、それを使うクラスが生きている時だけ)、本体が self を使う
  クラス、それらの祖先。プレリュードの例外のクラスは `raise` や `rescue` を使うプログラムでだけ表に載る
- **まだのもの (P4c):** コアの実行時エラー (0 で割る、NoMethodError、型の違い、引数の数) は例外にならず、今までどおり
  エラーで止まる (rescue できない)。`loop` は StopIteration を捕まえない

### プレリュード

primitive を組み合わせるメソッドは、mruby の mrblib と同じく Ruby で書いて (`fpga/prelude/*.rb`)、**プログラムの前に置いて
一緒に compile する** (`mrbc -o out.mrb fpga/prelude/core.rb prog.rb` で1つの irep になる)。コアはそれを普通のメソッドとして走らせる。
回路を増やさずに組み込みメソッドを足すため。今あるもの: `Integer#times` `upto` `downto`、`Array#each` `each_with_index` `map`
`==` `include?` `join` `inspect`、`Object#loop` `proc` `!=` `initialize` `nil?` `instance_of?` `===` `puts` `print` `p` `format`、
`NilClass#nil?`、`Module#===` `name`、String のメソッド (上の「文字列と出力」)、例外のクラスと `raise` (上の「例外 (P4)」)。プレリュードは ROM を 4000 語ほど使う
(使わないメソッドも全部入る)。CRuby / picoruby でも同じ意味になる書き方だけで書く
(参照の突き合わせは CRuby の組み込みと比べる)。

### ROM 形式と変換 (#7)

`tools/fpga/rite.rb` が RITE0400 を読み、`tools/fpga/rom.rb` が ROM にする。**変換器は PicoRuby で書き、
PicoRuby の host VM で走らせる。** rake は起動と受け渡しだけをする (`FpgaConverter.run`)。**1命令1語の固定長 48bit**:

| bit | 中身 |
|---|---|
| [47:40] | op (mruby の opcode 番号そのまま。FPGA だけの命令は 0xF0 から) |
| [39:32] | a |
| [31:16] | b (BB の b / BS の s / S の s / BSS の上位16bit) |
| [15:0] | c (BBB の c / BSS の下位16bit) |

`LOADI32` (BSS) の 32bit が b:c にそのまま収まるので、例外の無い形にできた。変換で済ませること:

- **ジャンプ先は絶対語アドレスにする。** mruby は「operand を読み終えた位置からのバイト相対 (int16)」
- **`GETGV` / `SETGV` の `Syms[b]` は I/O ポート番号にする。** 対応表は `tools/fpga/io_map.rb`
  (`$LED`=0 出力、`$LED2`=1 出力、`$BUTTON`=2 入力、`$CONSOLE`=3 出力 (console))。
  入力ポートへの代入は変換時に止める。表に無いグローバル変数は一般のグローバル変数で、定数の表に置き、
  一番外の先頭で nil にする (`LOADNIL R0` + `SETCONST`、self を作る前)
- **並び: pc 0 に `TABLE`、irep を親・子の順 (深さ優先)、データ (pool の文字列とシンボルの名前、1語 4バイト)、
  シンボル表 (シンボル番号 → {データの語アドレス, 長さ})、例外の表 (あれば。pc 1 の `HTABLE` が指す)、最後にメソッド表。**
  ROM は 8192 語 (`PC_BITS` = 13)。
  入り切らなければ変換時に止める
- **シンボルはプログラム全体で番号を振る。** 演算の落ち先 (`+ - * / == < <= > >= [] []=`) は 0 から固定
  (`OP_SYMS`、コアが番号を知っている)。`SEND` 系の b、`LOADSYM` / `TDEF` / `SDEF` の b はシンボルの番号
- **`GETCONST` / `SETCONST` の b は定数の番号** (クラスの名前なら `CLASS` にする。上の「対応命令」)
- 未対応の命令は、命令名と場所 (irep の番号と iseq 内のバイト位置) を全部並べて止める

ROM の空きは全 bit 1 (op 0xff = 未対応) で、プログラムの外へ出たコアはエラーで止まる。
`rom_test.rb` がコーパス全部について、変換結果を `.dump` (`mrbc -v`) と1命令ずつ突き合わせる。

**変換器は PicoRuby と CRuby の共通部分で書く。** 同じ file を CRuby からも読み (`tools/fpga/converter.rb`)、
参照インタプリタやテストが使う。`rom_test.rb` は、commit 済みの `.hex` `.lst` (PicoRuby の出力) と
CRuby で走らせた結果が一致すること、境界の値 (負の相対ジャンプ、`LOADI32` の全 bit 1) で両者が一致することを見る。
PicoRuby の host VM (`vendor/picoruby/bin/picoruby`) で実測した、使えないもの:

- `require` / `require_relative` が無い。複数の file は `picoruby a.rb,b.rb,c.rb` と `,` でつないで渡す
- `Struct`、`File.binread`、`String#force_encoding`、`Array#sort_by` `#sum` `#tally` `#flat_map` が無い
- Enumerator の連鎖 (`each_with_index.map`、`map.with_index`) は `fiber required for enumerator` で落ちる
- 正規表現はキャプチャ (`$1`) が取れない。`String#split(/\s+/)` は `TypeError`
- `File.open(path, "rb") { |f| f.read }`、`getbyte` `byteslice` `unpack`、`format`、`exit`、`STDERR` は使える。
  48bit の整数も扱える (`MRB_INT64`)

### ブロックと Proc

ブロックは Proc (ヒープのオブジェクト) になる。`BLOCK` が Proc を作り、`BLKCALL` がそれを呼ぶ。Proc は
先頭 pc・引数の数・lambda の印・nregs と、**作ったフレームの env と、そのフレームの Proc** (外側への鎖) を持つ。

- **env (mruby の REnv と同じ)。** フレームの中で初めて Proc を作った時に、Proc と一緒に1回で確保する。
  フレームが生きている間は bp を指し、外側の変数はレジスタファイルを読み書きする。**フレームから戻る時
  (`RETURN` `RETNIL`、`break` や `return` で畳む時も) に、そのフレームの nregs 本のレジスタを env に写し取り**
  (S_DETACH、1 cycle 1本)、以後はヒープの写しを読み書きする。メソッドが返した Proc が、戻った後のメソッドの変数を数え続けられる

- **iterator はプレリュードのメソッド。** `times` `upto` `downto` `each` `each_with_index` `map` `loop` は `yield` する
  普通のメソッドで、ブロックは `SENDB` (ブロックを渡す印付きの `SEND`) で渡る。
- **`proc { }` はプレリュード、`lambda { }` は Proc に lambda の印を付けて返す primitive、`-> { }` は印付きの `BLOCK`。**
  `.call(...)` は Proc#call (primitive、`BLKCALL` と同じ)。ブロックのフレームの R0 は Proc を作った時の self。`BLKCALL` は
  フレームを作るだけで、引数はブロックの先頭の `ENTER` が並べる。proc は数を調べず (足りなければ nil、多ければ捨てる、
  配列1つなら展開する)、**lambda は数が違えばエラー**。
  lambda の中の `break` と `return` は lambda から戻る (`return` は、囲むメソッドまでの間で一番内側の lambda から)
- **メソッドへのブロック** は呼び出しの c に印 (0x80) を付け、呼び出し先のブロックの枠 (引数の後ろ) に置いたまま呼ぶ。
  `yield` は `BLKPUSH` (枠から Proc を取る) + `BLKCALL`、`&blk` は引数として受け、`block_given?` は `BLKPUSH` の後に `!` を2回
- **外側の変数 (`GETUPVAR` / `SETUPVAR`)。** c = 何段外のフレームか (mruby の深さ + 1)。コアは今の Proc から鎖を c 段
  たどって (1 cycle 1段、S_WALK) そのフレームの env を得て、生きていればレジスタファイル、退避済みならヒープの写しの
  b 番目を読み書きする (写しへの書き込みはトレースに出ない)
- **`break` (`BREAK`)。** Proc を作ったフレームまでコールスタックを畳み、そのフレームから呼んだ所へ値を持って戻る (c = 1。
  変換器は c = 1 だけを出す。c = 0 はフレームを1つ畳んで b へ飛ぶ)。`next` は普通の `RETURN` / `RETNIL`
- **ブロックの中の `return` (`RETURN_BLK`)。** c = ブロックを囲むメソッドまでの段数。そのメソッドのフレームまで畳んでから戻る。
  メソッドの外 (一番外) のブロックの `return` は、間に lambda が無ければ変換時に止める
- **もう戻ったフレームへの `break` / `return` はエラー** (Ruby の LocalJumpError)

### 配列とヒープ

- **ヒープは 2048 語 (1語 = タグ + 32bit) を半分ずつ使う。** 確保は先頭から詰めるだけ (bump)。半分が足りなくなると
  **Cheney のコピー GC** でもう半分へ写し、それでも足りなければエラーで止まる
- **オブジェクト。** 見出し (タグ 8、値 = クラスの番号 << 16 | 語数) の後ろに中身。クラスの番号は
  `tools/fpga/isa.rb` の `CLASSES` (組み込み) と、ヒープの中だけの塊 (配列の中身 `CLS_DATA`、env `CLS_ENV`)。
  配列は `[見出し] [長さ] [中身への参照]` と、別の塊 `[見出し] [要素 × 容量]`。
  Proc は `[見出し] [先頭 pc | lambda << 23] [env] [外側の Proc] [作ったフレームの self]`。
  env は `[見出し] [生きている間の bp か nil] [レジスタ × nregs]`。配列の中身と env への参照も Object のタグで指す
  (レジスタには出ない。種類は見出しで分かる)
- **配列を伸ばす** (`a[i] = v` で i が容量以上、`push`) 時は、容量 max(i + 1, 2 倍, 4) の塊を新しく取り、写して付け替える。
  間は nil
- **GC の根は、レジスタファイル全部 (番号順)、代入済みの定数 (番号順)、コールスタックの Proc と env (底から1段ごとに
  Proc、env の順)、今の Proc、今の env。**
  参照インタプリタとコアが同じ順に写すので、GC の後のアドレスまでトレースで一致する。コアは1語1 cycle で写す
- **Array と Proc はピンに出せない** (`SETGV` でエラー)

### 時間待ち

- **`sleep_ms n` は n ms、`sleep n` は n 秒待って n を返す。** 整数だけ (負はエラー)
- **時計は 1ms ごとの `ms_tick`。** コアは待つ間 `ms_tick` を数えるだけで、命令は進まない。
  `peridot_air_top.sv` の `MS_CYCLES` (既定 50,000 = 50MHz の 1ms) が `ms_tick` の間隔。
  ボードエミュレーターは周波数と時刻の倍率から計算して渡すので、クロックを変えても待ち時間は変わらない
- **参照インタプリタとトレースは時間を持たない。** 待ちは 1 step で、値 (n) だけを比べる。待つ長さは
  `mrb_core_tb` (100 ms で 100 cycle 前後) とボードエミュレーター (`blink_sleep.rb` が 0.1 秒ごとに反転) で見る

### CPU コア (#8)

`fpga/rtl/mrb_core.sv`。**多サイクル、1命令 2 cycle** (FETCH で ROM を引き、EXEC で実行と書き戻し)。
パイプラインは後回し。`en` (クロックイネーブル) が 0 の cycle は何も進まない。

- **レジスタ窓。** レジスタファイルは 128本 × 36bit を全フレームで共有し、R[i] は bp + i。呼び出しは呼び出し先の bp を
  呼び出し元の bp + a にし (呼び出し先の R0 = 呼び出し元の R[a] = 受け手)、呼び出し先の `ENTER` が残りのレジスタを
  1 cycle 1本ずつ nil で埋める (S_CLEAR)。`RETURN` は R0 (= 呼び出し元の R[a]) に値を置いて戻る。
  bp + nregs が 128 を超える、またはコールスタック (16段) が溢れるとエラー
- **実行中の命令は ir に取っておく。** メソッド探索の間、ROM の出力は表の語になるため (EXEC は ROM から、ほかの状態は ir から読む)
- **リセット後にレジスタファイルを1本ずつ nil で埋める (S_INIT、`en` に関係なく 128 cycle)。** 一括のリセットをしないのは、
  ブロック RAM にできる形にしておくためと、Verilator 5.020 が `always_ff` の for ループでの配列への `<=` を
  `BLKLOOPINIT` で受け付けないため
- `*` `/` `%` は組み合わせ回路 (`x / y` `x % y` を floor に補正)
`mrb_soc.sv` が ROM (8192語、同期読み出し) + コア + I/O (`mrb_io.sv`)。
出力ポートは最後に書いた値を持ち (書く前は nil)、`GETGV` で読み戻せる。入力ポートは Integer で読める。
`fpga/tb/mrb_core_tb.sv` が全対応命令とエラー停止を1つずつ確かめる (配列の伸長、GC 後も生きている配列、
ブロックの中の return、`sleep_ms` の待ち時間も)。

- **1命令 2 cycle は、ヒープとフレームを触らない命令だけ。** 配列・Proc を作る (S_ALLOC → 見出しと中身を1語ずつ)、
  配列を伸ばす (S_GROW)、GC (S_GC_ROOT → S_GC_SCAN)、外側のフレームをたどる (S_WALK)、例外と `break` / `return` で
  コールスタックを畳む (S_XSTART から、例外の表を1語ずつ引く)、メソッド探索 (S_LOOKUP / S_PROBE、1段に 2 cycle + 衝突した語の数)、`sleep_ms` (S_SLEEP) は
  数 cycle から数千 cycle かかる。トレースは命令ごとなので影響しない

### 正しさの基準 (#9)

`tools/fpga/ref_vm.rb` (参照インタプリタ) と `fpga/sim/mrb_run_tb.sv` (コアのシミュレーション) が
**同じ書式のトレース**を出す:

```
X <step> <pc> <op>          命令を実行した
W <step> <reg> <tag> <val>  レジスタに書いた
O <step> <port> <tag> <val> I/O に書いた
H|E <step> <pc> [op]        止まった / エラー
L <step>                    命令数の上限 (fpga:check は 20000)
```

- **合否は I/O の系列 (O 行) と終わり方。** step まで一致させる。無限ループのプログラムは命令数の上限で打ち切る
- **ずれたら、トレースで最初に食い違った step と命令を出す。** `SUB` を `x + y` に壊すと
  `first difference at step 8, pc 8 (SUB)` と出た
- **入力は step で与える。** `fpga/corpus/<name>.stim` に `<step> <port> <value>`。
  その step の命令から値が変わる (参照もシミュレーションも同じ)
- **差分ファズ (`rake fpga:fuzz[count,seed]`)。** 対応命令からランダムに ROM を組み (R0..R11 に乱数を入れる前置き付き、
  範囲外のレジスタ・0 で割る・深い再帰・未定義の定数・引数の数違いもわざと混ぜる)、後ろにランダムなメソッド表を置いて
  (親クラスの輪、メソッド、primitive、未対応の種類、輪になった親も混ぜる)、参照とコアでトレースを1行残らず比べる。
  4本に1本は**ヒープを突く形** (配列を作る・push・代入・添字・pop・Proc の呼び出し・多重代入、Proc を返すメソッドを
  呼んで戻った後に Proc を呼ぶ (退避済みの env、lambda、戻ったフレームへの break / return) を並べたループで、GC を何度も起こす。
  上限 3000 命令)。`sleep_ms` / `sleep` は混ぜない。
  終わりに、珍しい経路に届いた回数 (`reached: aref, detach, env_heap, found, gc, lambda_exit, super`) を出す。
  `fpga:test` は seed 1 で 300 本 (メソッド表で見つかった呼び出し 25262、親クラスへの段 4389、GC 135 回、env の退避 3360 回)。
  seed 1..9 で一致した。入力の刺激の適用順 (同じ port の行の順) の
  食い違いはファズが見つけた。`%` の floor 補正を壊すと、ファズもコーパスも落ちる
- **参照インタプリタ自体は別の実装と比べる** (`ref_vm_test.rb`):
  CRuby で同じ `.rb` を走らせ `trace_var` で拾った出力の系列 (入力を読まないプログラム。`sleep_ms` / `sleep` は待たずに n を返す)、
  picoruby host VM に `p [$LED, $LED2]` を足して走らせた最後の値 (止まるプログラム)

### PERIDOT-Air (#10 #11)

**実機・Quartus・USB-Blaster はまだ無い。以下はシミュレーションまでしか確かめていない。**

- **top は `fpga/rtl/boards/peridot_air_top.sv`。** `$LED`→`USER_LED[0]` (PIN_105)、`$LED2`→`USER_LED[1]` (PIN_119)、
  値が true か 0 以外の Integer なら点灯。`$BUTTON`←`D[0]` (PIN_84、内部 pull-up、GND に落とすと 1)。
  `RESET_N` (PIN_34、基板のリセットスイッチ) がコアのリセット。点灯の極性は未確認 (`LED_ACTIVE_LOW` で反転できる)
- **待ち時間はクロックイネーブルで作る。** CPU を `CE_DIV` cycle (既定 1000) に1回だけ進める。
  blink は 1回の反転に 7012 命令なので、50MHz なら約 0.28 秒ごとに反転する
  (Quartus と同じ `ROM_FILE` 経由の `$readmemh` で、CE_DIV=1 の時 14024 cycle ごとの反転をシミュレーションで確かめた)。
  `CE_DIV` に関係なく時間で待つなら `sleep_ms` (上の「時間待ち」)
- **ピンと Quartus の設定は osafune/peridot_air (MIT) の `fpga/air_blank_top/` から写した** (`fpga/boards/peridot_air/`)
- **合成 (`rake fpga:build`)。** `build/fpga/peridot_air/` に自己完結のプロジェクト (`.sv` の写し、全語を埋めた `rom.hex`) を作り、
  `quartus_sh` が PATH にあればそこで、無ければ `FPGA_QUARTUS_HOST=<ssh 先>` へ rsync して
  `quartus_sh --flow compile` → `quartus_cpf` で `.svf` まで作って戻す (`FPGA_QUARTUS_DIR` で送り先 dir)。
  Quartus の版は決め打ちしない。Apple Silicon では UTM の Debian arm64 + Rosetta 2 で 23.1std / 24.1std の報告がある。
  終わったら fit summary (LE・メモリ使用量) を表示する。**実測値はまだ無い** (#11 の完了条件)
- **書き込み (`rake fpga:flash`)。** Mac ネイティブの `openFPGALoader -c usb-blaster <svf>` で SRAM へ
  (電源を切ると消える)。`FPGA_CABLE` でケーブルを変えられる。EPCQ16 への永続書き込みはまだ無い
- **yosys は使えなかった。** Ubuntu 24.04 の yosys 0.33 は `import pkg::*` を読めず、LE の見積もりに使えない

### ボードエミュレーター

実機が届くまでの代役。`fpga/sim/board_emu_tb.sv` が実機の top (`peridot_air_top.sv`) をそのまま置き、
クロック・`CE_DIV`・`RESET_N`・`D[0]`・`USER_LED` を実機どおりに回して、ピンの変化を実時間で書く。

**クロックは既定 125MHz (Raspberry Pi Pico と同じ)、4つ目の引数 (MHz) で変えられる。** シミュレーションでは
周波数は時刻のラベルでしかないので、どこまでも上げられ、手元で走る時間は変わらない (PERIDOT-Air の水晶は 50MHz)。
CPU は1命令 2 cycle なので、`CE_DIV=1` なら 125MHz で 6250 万命令/秒。blink の反転は 125MHz・`CE_DIV=1000` で 0.1122 秒ごと、
50MHz で 0.2805 秒ごと、1000MHz で 0.0140 秒ごとだった。参照インタプリタと突き合わせる命令数も周波数から計算する。

`rake fpga:emu[fpga/corpus/blink.mrb,2000,1000,50]` (50MHz) で:

```
   0.000 s  LED    on
   0.281 s  LED    off
   0.561 s  LED    on
  ...
  LED  flips every 0.2805 s on average
  ok blink LED: 8 change(s), same as the reference interpreter
```

- **時刻を引き延ばして速く回す。** CPU は `en` の cycle でしか進まないので、回路の `CE_DIV` を 1/k にし
  (1命令あたり 10 cycle 以上は残す)、時刻を k 倍して表示する。`CE_DIV=1000` なら k=100 で、実機 2 秒分が
  0.3 秒ほどで回る。1:1 で回した結果との差は 10µs 以内だった。`FPGA_EMU_EXACT=1` で 1:1 (実機 1 秒分に 20 秒ほど)
- **`sleep_ms`。** `rake fpga:emu[fpga/corpus/blink_sleep.rb]` は `sleep_ms 100` の blink で、0.1000 秒ごとに反転する。
  50MHz・`CE_DIV=100` でも 125MHz・`CE_DIV=1` でも同じ
- **ボタン。** `<name>.buttons` (`fpga/corpus/button.buttons`) に `<ms> <0|1>` (1 = 押す) を書くと、その時刻に `D[0]` を落とす
- **参照と突き合わせる。** エミュレーターが実際に実行した命令の数 (ログの END 行) だけ参照インタプリタを回し、LED の点灯の変化の列が一致するかを見る。
  窓の端は ±4 命令の揺れを許す。ボタンを押すプログラムは、時刻と命令数を対応付けられないので突き合わせない。
  「参照の先頭と一致」だけだと、LED が点きっぱなしになる壊れ方 (`SUB` を足し算にした時) を見逃したので、変化の数まで比べる
- **見えないもの。** 点灯の極性、ピンの電気的なこと、Quartus での合成結果。これらは実機で見る

### 版と波形

確認した組み合わせ: Ubuntu 24.04 の apt (Verilator 5.020 / Icarus 12.0)。
Homebrew は Verilator 5.052 / Icarus 13.0 / Surfer 0.7.0 (Mac での実行は未確認)。
`--binary` は Verilator 5.002 以降。

**波形を見る。** `rake fpga:sim[counter8_tb]` の後に `surfer build/fpga/counter8_tb.fst`
(`fpga:run` は `build/fpga/rom/<name>.fst`)。
Mac は `brew install surfer` (`rake fpga:setup` が入れる)。Linux の apt には無いので
https://gitlab.com/surfer-project/surfer/-/releases のバイナリか
`cargo install --git https://gitlab.com/surfer-project/surfer surfer`。
GTKWave の Homebrew cask は 2025-10 に disable された。VSCode なら Vaporview 拡張でも開ける。
