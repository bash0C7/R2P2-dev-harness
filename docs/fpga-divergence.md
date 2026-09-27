# FPGA mruby コアの乖離表 (2026-09-27 見直し)

P0〜P9 で作ったコアを、issue #4 の目標と mruby の仕様と PERIDOT-Air の資源に照らした表。
実装を重ねる前に、どこがどれだけずれているかを1か所にまとめる。設計の正本は [spec.md](spec.md) §10、この表はその見直し。

**目標 (3つを同時に満たす。issue #4 と user の指示):**

1. **mruby の意味で `.mrb` を実行する。** 命令の意味の正本は mruby の `include/mruby/ops.h`、`src/vm.c`、`doc/internal/opcode.md`
   (vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/、RITE0400、119 命令)
2. **PicoRuby のプログラムが動く。** 正しさの基準は host の PicoRuby (mruby) と同じ出力。PicoRuby の gem の mrblib はそのまま使う
3. **PERIDOT-Air に載る。** EP4CE6E22C8N: 6,272 LE、M9K 30 個 (276,480 bit)、18×18 乗算器 15、SDRAM 256 Mbit、水晶 50 MHz。
   クロック周波数と bit 数は制約しだいで見直す (user)

調べ方: 命令・実行時のモデル・gem とプレリュード・資源の4つを、コードと mruby のソースの対照で調べた (実行して確かめていない行は「推定」)。
資源は yosys 0.33 (`synth_intel -family cycloneiv`) で部品を単体で合成した値 [実測] と手計算 [推定]。Quartus の fit はまだ無い。

---

## A. 正しさの基準の乖離 (一番根)

| 今 | あるべき | 乖離 |
|---|---|---|
| `fpga:check` と `fpga:gap` の「一致」は参照 (`tools/fpga/ref_vm.rb`) とコアのトレースが同じこと | host の PicoRuby と出力が同じこと | 参照そのものが mruby と違っても「一致」になる。gem の test の adc_test は stub が FPGA に無いのに「一致」。host と比べているのは corpus の数本 (tasks sends int64 picotest caller) だけ |
| 段の目標は gap の example が通る本数 | 3つの目標の乖離が減ること | 足りない所をプレリュード・gem・primitive で継ぎ足してきた (場当たり)。乖離は表にされず増えた |

## B. 命令の乖離

119 命令のうち、コアがそのまま実行 69、変換器が別の命令に置換 22、変換時に解決 11、無し 17。FPGA だけの命令 `TABLE` `HTABLE` `LOADF` `LOADI64`。

- **コアは `.mrb` を読まない** (issue #4 は「`.mrb` の命令を直接デコード」)。変換器 (`tools/fpga/rom.rb`) が 48bit 固定長の語
  `[op|a|b|c]` にし、ジャンプを絶対番地、`Syms[b]` を全体のシンボル番号、`Pool[b]` を ROM の番地と長さ、`Irep[b]` を pc に置き換え、
  ENTER の 24bit と呼び出しの c の意味を並べ替える
- **変換時に解決:** CLASS MODULE TDEF SDEF ALIAS SCLASS GETMCNST SETMCNST ほか (C の1)
- **無し:** GETSV SETSV MATCHERR CALL ARYSPLAT ASET INTERN SYMBOL METHOD DEF UNDEF TCLASS DEBUG ERR EXT1 EXT2 EXT3
  (EXT が無いので、1つの irep のシンボル・pool・子・レジスタが 255 を超えると変換で止まる)
- **意味の違い:**
  - ADDILV / SUBILV: 受け手が Integer でなければメソッドを送らずに停止 (vm.c は送る)
  - BLKPUSH: ブロックが無くても LocalJumpError "unexpected yield" を投げず nil を置き、後の BLKCALL で停止
  - SENDB: Proc でない値に `to_proc` を送らない。ARYCAT: `to_a` を呼ばない
  - 実行時のエラー (0 除算、NoMethodError、ArgumentError、TypeError) が例外になるのは、プログラムに rescue / ensure がある (例外の表がある) 時だけ。無ければ停止

## C. 実行時のモデルの乖離 (深刻な順)

| # | 項目 | mruby | コアの今 | 深刻度 |
|---|---|---|---|---|
| 1 | クラスとメソッドの定義 | 実行時 (OP_CLASS、OP_TDEF)。実行した順に効く | 変換時にメソッド表を作る。後の def が最初から勝つ。条件付きの def も確定。`define_method`、`undef`、`remove_method`、`method_missing`、`extend`、`prepend`、特異メソッド (`def obj.x`、`class << obj`)、`instance_eval` / `class_eval` が無い | 高 |
| 2 | 定数の探索 | 字句 (cref) → cref の祖先 → Object (variable.c `mrb_vm_const_get`) | 字句の入れ子だけ。親クラスと include した module の定数が見えない。未定義は NameError でなく停止 | 高 |
| 3 | `module_function` | 特異クラスに写す | 何もしない (`M.f` が呼べない、推定) | 高 |
| 4 | 資源の枯渇 | SystemStackError (128/512 段)、NoMemoryError | 呼び出し 32 段 × レジスタ 128 本、ヒープ 32768 語 (1 バイト 1 語)。溢れると停止 | 高 |
| 5 | Symbol | 実行時に intern できる | 変換時に固定。`to_sym` は無い名前で ArgumentError、`:"#{x}"` は変換で止まる | 高 |
| 6 | 組み込みのサブクラス | `class Foo < Array` | `new` できるのは Object、Hash、Range、Exception、プログラムのクラスだけ。`String.new` は停止 (推定) | 高 |
| 7 | オブジェクト | object_id、dup / clone、freeze、private | ヒープのオブジェクトの object_id は NotImplementedError (コピー GC で動く)、Object#dup / clone 無し、`frozen?` は常に false、private は無視 | 中 |
| 8 | インスタンス変数 | 実行時に増える | 並びを変換時に固定。`instance_variable_get` / `set` 無し | 中 |
| 9 | その他 | — | `send` の引数は 6 個まで、`loop` が StopIteration を捕まえない、`backtrace` 無し、`Object#hash` は常に 0、`inspect` の形、eval / Struct / Data / Regexp / Method / pack / ObjectSpace 無し | 中〜低 |

一致しているもの: Integer (64bit、桁あふれの RangeError とメッセージ)、rescue / ensure / retry、include、クラスの再オープン、ブロックと env の退避、Task。

## D. gem とプレリュードの乖離

- **gem:** `fpga/gems/` の 15 file が PicoRuby の gem の mrblib を書き直している (規則「mrblib はそのまま、C の所だけ書く」に違反)。
  gpio machine uart rng irq pwm adc watchdog io_console i2c spi time vram bdffont task (Queue) signal picorubyvm file、
  midibase_fpga.rb は mrblib の `midi_read_timestamp_us` を上書きしている。
  mrblib をそのまま使えているのは vendor の mrblib だけの gem (ssd1306 uc8151 hcsr04 rotary_encoder midibase-mml uart-midi json) と psg / env / picotest。
  目立つ挙動の違い: `Machine.sleep` の範囲の検査が無い (gem の test で T 行)・不正な level で無限ループ、irq が 1ms のポーリングで bridge と `UART#irq` が無い、
  GPIO の値の検査と `GPIO::Error` が無い、`SPI.new` の置き換え、Queue の timeout が無い
- **原因:** spec.md §10 の方針「gem は FPGA 版を書く (mrblib は `Object.const_defined?` や `module Kernel` を使うので使わない)」が古いまま残っていた
- **プレリュード:** mruby の core の mrblib を 86 メソッド書き直している (Comparable、Enumerable、Array / Hash の多く、`Integer#times`、`String#%` `gsub` `sub`、`Symbol#to_proc`)。
  R2P2 に入らない ext の API を 33 メソッド持つ (R2P2 で NoMethodError のプログラムが FPGA で通る)。
  mrblib をそのまま載せるのに要るもの (推定): `to_enum`、C の helper (`__svalue` `__fill_exec` `__update_hash`)、`Object.const_defined?`、`module Kernel`、`**opt`、
  `begin require … rescue LoadError`、`module A::B`、`def self.new` と alloc、`private :a`

## E. 資源の乖離

### 記憶 (既定の値)

| 配列 | 深さ × 幅 | bit | 読み方 |
|---|---|---|---|
| heap (mrb_core.sv:215) | 65,536 × 68 | 4,456,448 | 組み合わせ読み、異なる添字が約 59、2〜3 段の連鎖読み |
| ROM (mrb_soc.sv:41) | 32,768 × 48 | 1,572,864 | 同期読み。最小の blink でも 5,897 語 = 283,056 bit (M9K 全体より大きい。大半はプレリュード) |
| regs (:129) | 1,024 × 68 | 69,632 | 組み合わせ読み 4 ポート以上、同じ cycle に書き込み 3 本 |
| コールスタック ret_* (:138-144) | 256 × 186 | 47,616 | 組み合わせ読み |
| PSG の列 (mrb_dev.sv:127-129) | 256 × 80 | 20,480 | 組み合わせ読み |
| consts (:175) | 256 × 68 | 17,408 | 組み合わせ読み 2 ポート |
| **合計** | | **6,187,136 (6.19 Mbit)** | **M9K 全体の 22.4 倍** |

組み合わせ読みの記憶は M9K にならず flip-flop と mux になる (yosys でも全部 "list of registers")。256 × 68 の1ポートで 31,098 cells、
同期読みにすると altsyncram 2 個 [実測]。

### 論理 [部品は実測、全体は推定]

| 部品 | 64bit | 32bit |
|---|---|---|
| 組み合わせの除算と剰余 | 7,376 | 1,919 |
| 乗算 (128bit の積、DSP なし) | 12,148 | 3,088 |
| 可変シフト | 888 | 380 |
| `fs_at` (3,216 bit から1バイト) | 2,762 | — |

- そのままの RTL: 記憶も flip-flop に展開されて約 10^8 LE (デバイスの 1 万倍のオーダー)
- 記憶を外に出し Float の real も除いても約 80〜110k LE (13〜18 倍)。mrb_dev の IRQ の標本取りが 512 段に展開される (mrb_dev.sv:321-340) のも大きい
- FSM 46 状態、opcode の腕 75、primitive の腕 98 (うち Float 54)

### 合成できない所

- Float: mrb_core.sv の `real`・`$bitstoreal`・`$sqrt` など libm (:381-396、:2013-2120)、f_fmod のデータで回数の決まるループ (:366-375)、
  fpconv (mrb_fpconv_pkg.sv、1664bit の多倍長整数と while)、`for k < arr_len` で heap を読む (:2030)

### 周波数 [推定]

- 今の RTL: 組み合わせの 64bit 除算が 1 cycle のパスにあり約 3 MHz。乗除算を多サイクルにしても 20〜25 MHz
- 125 MHz には、同期読みの M9K、1 段 1 演算のパイプライン、書き戻しの mux の分割が要る。それでも 64bit の値のパスで 60〜90 MHz、32bit で 80〜110 MHz
- 板の水晶と SDC (fpga/boards/peridot_air/peridot_air.sdc) は 50 MHz。既定の 125 MHz はシミュレーションの仮定で、板の上の根拠が無い

### 載せるための候補 [推定]

共通: ROM と heap は SDRAM と M9K の cache、regs は M9K (読みを1段のパイプラインに)、スタックと定数は同期読み、
除算は多サイクル (約 300 LE)、乗算は DSP、Float と数の文字列化は mruby ソースコードの soft-float、IRQ の標本取りは逐次。

| | 64bit の値 (R2P2 と同じ MRB_INT64) | 32bit の値 (MRB_INT32) | 最小 (32bit、SDRAM 無し) |
|---|---|---|---|
| M9K | 27 / 30 | 22 / 30 | 29 / 30 |
| LE | 10〜15k (載らない) | 5〜7k (ぎりぎり) | 3.5〜5k (載る) |
| Fmax | 50〜70 MHz | 75〜100 MHz | 50 MHz は確実 |

---

## まとめ: どこで道を外れたか

1. **正しさの基準が「参照とコアの一致」だった。** 参照が mruby とずれても誰も見ない。基準を host の PicoRuby にしなかった
2. **定義を変換時に決める作り (静的なメソッド表) を最初に選び、それが mruby の意味と違うことを表にしなかった。** 後から穴 (alias_method、caller、P9b の上書きの表) を継ぎ足した
3. **資源の予算を一度も見なかった。** 値 64bit、8 タスク、ヒープ 64K 語、Float、PSG、IRQ を全部内蔵の記憶と組み合わせの論理で作り、合成できない所も残した
4. **gem の規則を作った後も、前に書き直した gem を直さなかった** (spec の古い方針が残った)

この表を正本に、目標3つを満たす作りを計画し直す (docs/superpowers/plans/)。
