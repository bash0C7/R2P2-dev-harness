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

## 10. FPGA のシミュレーション

mruby のバイトコードを直接実行する CPU を FPGA に作る (issue #4)。実機 (PERIDOT-Air) に焼く前に、
シミュレータで万全に動かす。HDL とテストベンチは SystemVerilog、道具は Ruby (rake)。
設計: [docs/superpowers/specs/2026-09-26-fpga-sim-env-design.md](superpowers/specs/2026-09-26-fpga-sim-env-design.md)

| タスク | 意味 |
|---|---|
| `rake fpga:setup` | 足りないシミュレータを入れる。macOS は `brew install verilator icarus-verilog surfer`、Linux は `apt-get install -y verilator iverilog` (root でなければ sudo) |
| `rake fpga:doctor` | verilator / iverilog / vvp / surfer の有無と版。必須が欠けていれば落ちる |
| `rake fpga:test` | `fpga/tb/*_tb.sv` を全部、Verilator と Icarus の両方で回す。CI の `fpga` job が回す |
| `rake fpga:sim[tb]` | 1本を Verilator で回す。波形は `build/fpga/<tb>.fst` |
| `rake fpga:sim:icarus[tb]` | 1本を Icarus で回す。波形は `build/fpga/<tb>.icarus.fst` |

`vendor/picoruby` は要らない (`rake setup` 無しで回る)。`rake test` には含まれない。

**置き場所。** 回路は `fpga/rtl/**/*.sv` (全部を毎回コンパイルに渡す)、テストベンチは
`fpga/tb/<name>_tb.sv` で top module 名を file 名と揃える。各 file に `` `timescale 1ns / 1ps `` を書く
(1つでも書くと、書いていない module を Verilator が `TIMESCALEMOD` で落とす)。

**合否。** テストベンチは合格なら最後に `PASS <tb名>` を出して `$finish`、食い違えば `$fatal`。
rake は exit status が 0 **かつ** `PASS <tb名>` 行がある時だけ合格にする。
`+dump=<path>` が渡された時だけ `$dumpfile` / `$dumpvars` で波形を書く (`fpga/tb/counter8_tb.sv` が雛形)。

**Verilator だけではリセット漏れを見逃す。** Verilator は2値なので、リセットされない register は 0 から
始まり、たまたま期待値と合う。counter8 のリセット代入を消すと、Icarus は最初の check で
`count is X/Z` で落ちたが、Verilator は数え終わった後の非同期リセットの check まで通った。
テストベンチはリセット直後に `$isunknown` を見る。

**Verilator の -Wall。** warning は error になる。テストベンチの `always #5 clk = ~clk;` は `BLKSEQ` に
引っかかるので、そこだけ `/* verilator lint_off BLKSEQ */` で囲む。`$fatal` は abort() なので、
rake には exit code ではなく signal 6 として返る。

**版。** 確認した組み合わせ: Ubuntu 24.04 の apt (Verilator 5.020 / Icarus 12.0)。
Homebrew は Verilator 5.052 / Icarus 13.0 / Surfer 0.7.0 (Mac での実行は未確認)。
`--binary` は Verilator 5.002 以降。

**波形を見る。** `rake fpga:sim[counter8_tb]` の後に `surfer build/fpga/counter8_tb.fst`。
Mac は `brew install surfer` (`rake fpga:setup` が入れる)。Linux の apt には無いので
https://gitlab.com/surfer-project/surfer/-/releases のバイナリか
`cargo install --git https://gitlab.com/surfer-project/surfer surfer`。
GTKWave の Homebrew cask は 2025-10 に disable された。VSCode なら Vaporview 拡張でも開ける。

**合成と実機はまだ無い。** Cyclone IV の bitstream は Intel Quartus でしか作れない (macOS 版なし)。
道具立ては issue #10、実機は #11。
