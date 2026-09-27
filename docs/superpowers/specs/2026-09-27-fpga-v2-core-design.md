# FPGA mruby コア v2 の設計 (V1)

計画: [plans/2026-09-27-fpga-v2.md](../plans/2026-09-27-fpga-v2.md)。乖離の表: [fpga-divergence.md](../../fpga-divergence.md)。
mruby の出どころは `vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/` (以下 `mruby/`)。

**何を作るか:** FPGA (PERIDOT-Air) の上に、mruby のバイトコード (`.mrb`) を機械語として直接実行する CPU を作り、
それを核にした mruby ネイティブのマイコンボードとして実機で動かす。使い方は R2P2 と同じ (電源投入 → shell、app の自動実行、ピンを mruby ソースコードで)。
完成形 (板の振る舞い、代表の動作の Lチカ、中身、意味の契約、完成の条件 M1〜M5) は [計画の §1〜§5](../plans/2026-09-27-fpga-v2.md) が正本。この文書はその中身の作り。

**制約:** mruby の意味で `.mrb` を実行する / PicoRuby (R2P2) のプログラムが host の PicoRuby と同じ出力で動く /
PERIDOT-Air (EP4CE6、6,272 LE、M9K 30、乗算器 15、SDRAM 32 MB) に載り、100 MHz をねらう (50 MHz は最初の足場)。
mruby と違えるのは資源と回路の都合だけで、全部 [乖離表](../../fpga-v2-deviations.md) に載せる。

---

## 1. 作りの考え方: 速い道は回路、残りは firmware (mruby ソースコード)

mruby は「VM (vm.c) と、C で書いたメソッド (ROM のメソッド表)、mrblib (mruby ソースコード)」でできている。v2 はこれを写す。

| mruby | v2 | 理由 |
|---|---|---|
| vm.c の命令の実行 | **回路** (命令の取り出し・デコード・レジスタ・ALU・分岐・メソッドの cache の当たりの呼び出し・戻り) | 毎命令の速さ |
| vm.c の遅い道 (メソッドの探索の外れ、`method_missing`、ブロックの作成、例外の巻き戻しの一部)、class.c・gc.c・symbol.c・variable.c・load.c | **firmware**: コアで走る mruby ソースコード。回路は「罠 (trap)」で firmware のメソッドを呼ぶ | LE を食わない。mruby の C と1対1に写せる |
| C で書いたメソッド (string.c array.c hash.c numeric.c … と gem の src/) | **firmware** (大半)。速さの要るものだけ回路の primitive | 353 + gem の C を回路にすると載らない (V1 の棚卸し) |
| mrblib (core と gem) | **そのまま** (mrbc の `.mrb` を読み込んで実行する) | 目標2 |
| ROM のメソッド表 (`MRB_MT_INIT_ROM`、class.h:164)・presym (presym.h) | **build の時に作る表** (firmware の C の代わりのメソッドと、そのシンボル) | mruby 自身が C のメソッドとシンボルを build の時に固定している。実行時の定義はその上の層 (class.h の ROM の層の鎖) |

firmware は mruby ソースコード (`fpga/firmware/*.rb`) で、mruby の C の関数ごとに対応する (出どころの file と関数を注釈に書く)。
firmware は特権の primitive (記憶の生の読み書き、オブジェクトの見出し、cache の消去など) を使える。プログラムからは見えない (名前が `__` で始まり、ROM の表の firmware の層だけにある)。

**罠 (trap):** 回路が自分で終えられない場合に、firmware の決まったメソッドを「呼び出し」として呼ぶ。引数はレジスタの窓に置き、戻ったら続きから。
罠の表 (番号 → firmware のメソッド) は build の時に作る。例: `__trap_method_missing(recv, mid, args)`、`__trap_alloc(size)`、`__trap_gc`、`__trap_raise(klass, msg)`。

## 2. 値 (mruby の MRB_NO_BOXING、MRB_INT64 と同じ意味)

| 項目 | 決めたこと | mruby |
|---|---|---|
| レジスタ 1 本 | 72bit = M9K の ×36 の 2 語: 下の語 {tag 4, 値の下位 32}、上の語 {予約 4, 値の上位 32} | `mrb_value` = {union 64bit, tt} (value.h、boxing_no.h) |
| tag | nil false true Integer Symbol Float (即値)、Object (ヒープの参照、下位 32 = 語の番地)、ほか (V2 で表にする) | `enum mrb_vtype` |
| Integer | 64bit の2の補数。32bit の ALU で下位・上位の2回 (桁上げ・借り)。桁あふれは RangeError (mruby と同じメッセージ) | numeric.c:33 付近 |
| Float | IEEE 754 double のビットを即値に持つ。演算は firmware の soft-float (Integer の演算で)。数の文字列化も firmware | MRB_NO_BOXING では即値 |
| Symbol | 32bit の番号。presym (build の時) と実行時の intern (firmware のハッシュ表) | symbol.c |
| ポインタ | 32bit の語の番地 (SDRAM は 32 MB = 8M 語、23bit) | — |

## 3. 記憶の配置

| 置き場 | 中身 | 大きさ |
|---|---|---|
| SDRAM (32 MB) | 起動の像 (firmware・mrblib・プログラムの `.mrb` をそのまま並べたもの、presym の表、ROM のメソッド表)、ヒープ (オブジェクトの枠と可変長の領域)、VM のスタック (レジスタの窓の後ろ)、シンボル表 | 像は約 0.3 MB (mrblib 216 KB + firmware)。フォントの表 (shinonome 810 KB) を入れても 2 MB 未満 |
| M9K | レジスタの窓 (VM のスタックの先頭の cache)、コールスタックの先頭、命令の cache、データの cache、メソッドの cache | 予算の表 (§9) |

- **命令は `.mrb` のバイト列のまま** SDRAM に置き、命令の cache を通して読む。可変長 (Z B BB BBB BS BSS S W と EXT1〜3、ops.h) のデコードは回路
- **起動の像を作る道具は `.mrb` を変えない。** 並べて見出し (各 `.mrb` の番地、presym の表の番地、ROM のメソッド表の番地) を付けるだけ。
  presym と ROM のメソッド表は firmware のソースから作る (mruby の presym の scan と同じ役)
- 板の上では、起動時に EPCQ (設定用の flash) から SDRAM へ像を写す (V5)。シミュレーションでは tb が SDRAM のモデルに読み込む
- **機械の状態は mruby の struct の形でメモリ (SDRAM) に置く:** `mrb_state` (exc、globals、object_class、top_self、シンボル表、`mrb_gc`)、
  `mrb_context`、`mrb_callinfo` (`include/mruby.h`)。layout.rb の field ごとに `# C: struct <名>.<field>` を書く。
  M9K のレジスタの窓とコールスタックの先頭は、そのメモリの cache (写し書き)。参照 v2 も同じで、CRuby 側に持てるのは回路のレジスタと cache に当たるものだけ。
  firmware (gc.c の `mark_context` の写しなど) がメモリから状態を読めるようにするため (86921ce はこれが無く、保守的な根にして壊れた)

## 4. 起動 (mruby の mrb_open と mrb_load_irep に当たる)

1. 回路の起動の段: 像の見出しを読み、firmware の `.mrb` の irep を実行し始める
2. firmware の init (mrb_init_core に当たる): 組み込みのクラス (BasicObject Object Module Class … class.c の mrb_init_class) を作り、ROM のメソッド表を
   クラスに付け、presym を登録する
3. mrblib の `.mrb` を順に読み込んで実行する (mrb_load_irep、load.c)。**クラスとメソッドは実行時に定義される** (OP_CLASS、OP_TDEF)
4. プログラムの `.mrb` を読み込んで実行する

`.mrb` の読み込み (load.c の read_irep) は firmware: irep の見出し・pool・syms を読み、syms を intern して irep の表を作る。
命令列そのものは写さず、SDRAM の `.mrb` の中を指す。

## 5. クラス・メソッド・呼び出し (mruby と同じ意味)

| 項目 | 決めたこと | mruby |
|---|---|---|
| クラス | ヒープの RClass (親、メソッド表、定数表、iv 表、フラグ、名前)。特異クラス、iclass (include / prepend)、BasicObject | class.c、class.h |
| メソッド表 | クラスごとのハッシュ表 (ヒープ、firmware) + その下に ROM の層 (build の時) | class.c の mt、mrb_mt_init_rom |
| 定義 | OP_CLASS / MODULE / SCLASS / TDEF / SDEF / DEF / ALIAS / UNDEF は罠で firmware。**実行した時点で効く** | vm.c の各 OP |
| 探索 | 回路のメソッドの cache ({クラス, シンボル} → {種類, 飛び先})。外れたら罠で firmware が親をたどる (mrb_method_search_vm) | vm.c、class.c:mrb_method_search_vm、MRB_METHOD_CACHE |
| cache の消去 | 定義・include・prepend・remove・undef で firmware が cache を消す | mrb_method_cache_clear |
| method_missing | 見つからなければ firmware が method_missing を引き、`:名前` を先頭に入れて呼ぶ。無ければ NoMethodError | vm.c:1411、1760 |
| 飛び先の種類 | irep (mruby ソースコードのメソッド)、回路の primitive、firmware のメソッド、attr の読み書き (mruby の C の attr は closure。v2 は種類で持つ) | RProc の MRB_PROC_CFUNC |
| 呼び出しの深さ | VM のスタックは SDRAM にあり、レジスタの窓は先頭の cache。溢れたら窓を SDRAM へ追い出す。深さの上限は MRB_CALL_LEVEL_MAX (512) で SystemStackError | vm.c:49 |
| 可視性 | private / protected を mruby と同じく検査する (探索の結果の flag) | vm.c:1724 |

## 6. ヒープと GC

| 項目 | 決めたこと | mruby |
|---|---|---|
| オブジェクト | 固定長の枠 (RVALUE) を heap page に並べる。page の大きさは組み込みの profile の 128 (`MRB_CONSTRAINED_BASELINE_PROFILE`、`picoruby-mruby/mrbgem.rake`) | gc.c の `mrb_heap_page`、`add_heap` |
| 可変長の領域 | 文字列・配列の中身、heap page そのもの。estalloc (TLSF) を firmware に写す | `mrb_malloc` / `mrb_realloc` (`malloc_increase` の勘定も)、`picoruby-machine/lib/estalloc/estalloc.c` |
| 見出し | {クラス, tt, gc の色, frozen, flags} (MRB_OBJECT_HEADER と同じ中身) | object.h |
| 確保 | 回路の速い道: freelist の先頭を外す、0 で埋める、arena に積む、live と負債 (`gc_debt`) を数える。負債が閾値を超えた時、freelist が空の時、可変長が要る時 (ARRAY 系の buffer を含む) は罠で firmware | `mrb_obj_alloc_core` (負債の勘定まで写す) |
| arena | `mrb_gc.arena` はメモリにある。save は `mrb_vm_exec` の入口、restore は vm.c の命令ごと (棚卸しの arena の列、`cc -E` した vm.c から生成)。溢れたら広げる | vm.c、`gc_arena_keep` |
| GC | gc.c を写す: `root_scan_phase`、`mark_context` / `mark_context_stack` (使っていないスタックを nil で消す)、`gc_mark_children`、gray list、sweep と `obj_free`。object_id は番地から (動かない) | gc.c |
| GC の乖離 (乖離表の行) | 1 step で 1 周を終える (V2 の立ち上げ。V3e で incremental を写して消す)、minor GC 無し (host は generational が既定)、write barrier は呼ぶが空、step_limit を無視、scheduler の auto_step | gc.c の `incremental_gc`、`mrb_gc_init` |
| collecting の間 | 確保してはいけない。参照 v2 は例外にする | gc.c の `collecting` の検査 |
| 尽きた時 | NoMemoryError (mruby と同じ) | |

- 86921ce の自前の GC (可変長のブロックの独自ヒープ、保守的なスタックの根、輪の arena) は、この表の何とも合わず、2 回目の sweep で止まった。revert する (計画 S3)

## 7. 例外・ブロック・タスク

- **例外:** irep の catch handler の表 (rescue / ensure) を mruby と同じく使う。コアのエラー (0 除算、型、スタック、ヒープ、未定義の定数、
  LocalJumpError) も全部 mruby の例外にする。rescue の有無で振る舞いを変えない (v1 の停止は無くす)
- **ブロックと Proc:** RProc と REnv (mruby と同じ)。env の退避は firmware (罠)
- **タスク:** mruby-task (task.c) の scheduler を firmware に写す。時刻の割り込み (1 ms の tick) は回路が flag を立て、命令の切れ目で罠にする (mrb_tick)

## 8. デバイスと gem

- **板のモデルを1つにする。** GPIO UART PWM ADC I2C SPI タイマー watchdog を mmio のレジスタにし、同じモデルを
  (a) RTL (mrb_dev)、(b) 参照 (Ruby コード)、(c) host の oracle の posix の port (harness が用意する。firmware-patches か build_config の overlay)
  の3か所で持つ。刺激 (stim) を3つに同じく入れ、host の出力を基準にできるようにする
- **gem は mrblib をそのまま**、C の所 (src/mruby/*.c の Ruby から見えるメソッド) を firmware で書く。port の関数 (ports/rp2040/*.c) の一覧を mmio のレジスタの仕様にする
- **PERIDOT-Air に無いもの:** RP2 の PIO、BOOTSEL、USB (tud)、PSG の core1 と MCP4922 (PIO)。PIO 相当の回路を作るかは V4 で決める (予算しだい)
- v1 の `$LED` などの I/O のグローバル変数は持たない (PicoRuby に無い)

## 9. 資源の予算 (100 MHz、32bit の回路。V3 の各段の関所)

| 部品 | M9K | LE | 段数 (§10) | メモ |
|---|---|---|---|---|
| レジスタの窓 | 4 (512 語 × 2 × 36bit) | 150 | 同期読み 1 段 | 窓 256 本 (2 語ずつ) |
| コールスタックの先頭 | 2 | 100 | | |
| 命令の cache | 4 (4 KB) | 250 | | 直接写像、SDRAM の burst で埋める |
| データの cache | 8 (8 KB) | 350 | | write-back |
| メソッドの cache | 2 | 150 | | 256 行 (mruby の MRB_METHOD_CACHE_SIZE 既定と同じ) |
| デコードと制御 | 0 | 1,200 | | 可変長のデコード、命令ごとの状態機械 |
| ALU (32bit、64bit は2回) | 0 | 500 | 加算 1 本 | 比較・論理・シフト (多サイクル) |
| 乗算 (32×32 を DSP 4 個、64bit は部分積を回す) | 0 | 150 | | 乗算器 4〜8 |
| 除算 (多サイクル、1 bit/cycle) | 0 | 300 | | |
| SDRAM の制御 | 0 | 400 | | PERIDOT-Air の SDRAM (型番は V3a で確かめる) |
| デバイス (GPIO UART PWM ADC I2C SPI タイマー watchdog) | 2 | 1,000 | | |
| 余り | 8 | 1,700 (27%) | | 配置配線の余裕と PIO など |
| **合計** | **22 / 30** | **4,550 / 6,272** | | |

数は見込み。各段で `rake fpga:synth` の実測に置き換える。
確保の速い道 (freelist、0 で埋める、arena、負債の勘定) の LE とサイクルは、計画 S6 で ref の形が決まった時に見積もってこの表に足す。

## 10. 100 MHz の段の切り方

- 1 段に演算を 1 つ (32bit の加算 1 本 + LUT 6 段、`FpgaSynth::DEPTH_100MHZ`)
- M9K は同期読み。レジスタの読みはパイプラインの 1 段にする
- 64bit の Integer は 2 cycle、乗算は部分積を段に分ける、除算は多サイクル
- メソッドの cache の比較は 1 段、当たりの飛び先の読みは次の段
- SDRAM は cache の外れの時だけ (待ちは状態機械で吸収)

## 11. 正しさの確かめ方

- **oracle:** host の PicoRuby の出力 (`rake fpga:oracle`)。device のプログラムは §8 の板のモデルで host と同じ刺激
- **参照 v2 (V2):** Ruby コードで、回路の命令の実行と罠を写す。firmware は同じ mruby ソースコードを参照の上で走らせる
  (firmware の正しさは参照の上で host と比べて先に固める)
- **コア (V3):** 参照とトレースの一致 (差分ファズ) + host との一致 + 資源の関所

## 12. 決めていないこと (段で決める)

| 項目 | 段 |
|---|---|
| tag の全部の割り当て、ヒープの枠の大きさ | V2 (参照を書く時) |
| 罠の一覧と、回路の primitive の一覧 (どの C のメソッドを回路にするか。速さを測って決める) | V2 で firmware を書きながら、V3 で測って |
| GC の incremental を写す時期 (完成形は incremental。止まる GC は確定した短い遅延と両立しない) | V3e (V2 は 1 step で 1 周の乖離) |
| PIO 相当の回路 | V4 (予算の余り) |
| 板の上の起動 (EPCQ → SDRAM) | V5 |

## 13. 危うい所

- **firmware の量:** mruby の C が約 39,000 行、範囲内の gem の C が約 22,700 行。これを mruby ソースコードに写すのが一番の仕事量。
  段を分け (core のクラス → mrblib が要る helper → gem)、oracle で1つずつ固める
- **速さ:** 罠と firmware の多い道 (文字列の操作、ハッシュ、GC) は遅い。制御の用途 (LED、ボタン、UART、音) で足りるかを V3 で測り、
  足りない所だけ primitive にする (予算の余りから)
- **SDRAM の待ち:** cache が外れると数十 cycle。命令の cache の大きさは測って決める

## 14. V2a で決めたこと (参照 v2 の骨)

- **記憶の配置** は `tools/fpga/v2/layout.rb` (値 16 バイト、見出し 8 バイト、枠 64 バイト、tt は mruby の `enum mrb_vtype` と同じ番号、
  RClass・RString・RArray・RProc の欄、メソッド表、irep の構造体、起動の像の見出し)
- **特権の primitive (`__fpga_*`)** は、回路が symbol だけで引く表 (起動の像が持つ) で実行する。クラスを引かない (mruby の C の関数の直接の呼び出しに当たる)。
  メソッドの探索の外れの罠 (firmware) は、中で `__fpga_*` と命令だけを使う (自分がまた外れて罠に入らないため。firmware_test が確かめる)。
  プログラムの `__fpga_` で始まる名前は使えない (予約)
- **コアのクラス** (BasicObject Object Module Class Kernel と組み込みの型、それぞれのメタクラス) は起動の像の道具が作る (mruby の mrb_init_class と同じ形と親)。
  firmware の `class X ... def ... end end` を道具が読み (CLASS / MODULE / EXEC / TDEF / SDEF / ALIAS だけを許す)、X の ROM のメソッド表にする。
  実行時の定義 (プログラムと mrblib) は X の実行時のメソッド表に入り、ROM の表より先に引かれる (mruby の ROM の層と同じ)
- **シンボル表** は開番地法 (FNV-1a 32bit、65536 行)。番号 = 行の位置。presym (firmware の名前と、コアのクラスの名前) は道具が入れ、
  実行時の intern は firmware が同じハッシュ関数で入れる (両方が同じ表になることを firmware_test が確かめる)
