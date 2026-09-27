# FPGA mruby コア: P8 の後の残り (並列化、picotest、pitchdetector、pio、host 突き合わせ) の計画

> 書き方は superpowers の writing-plans の形 (目標 → 作り → 段ごとの作業、files、手順、確かめ方) に合わせた。
> この session には superpowers の skill が入っておらず (`superpowers:writing-plans` は Unknown skill)、skill の出力ではない。

**目標:** `rake fpga:test` と `rake fpga:gap` を CPU の数だけ並列に回して待ち時間を縮め、gap で止まっている 5 本
(picotest 3 本、pio 1 本、pitchdetector 1 本) をシミュレーターで動かすか、動かさない理由を gap に書く。

**用語 (使い分ける):**
- **mruby ソースコード:** 拡張子 `.rb` の、mruby の文法のファイル。mrbc で mruby bytecode にし、PicoRuby の VM か FPGA のコアで走る。
  `fpga/prelude/`、`fpga/gems/`、`fpga/corpus/`、PicoRuby の mrblib と example、変換器 (`tools/fpga/{isa,io_map,rite,rom,mrb2rom}.rb`、host の picoruby で走る)
- **Ruby コード:** CRuby で走るコード。参照インタプリタ `ref_vm.rb`、compare・gap・fuzz などの道具、`*_test.rb`、rake のタスク
- 文法はほぼ同じでも、どこで走るかで呼び分ける。「Ruby で書く」とは書かない
- **AOT (ネイティブのアセンブラーにする):** host 側の処理を速くする必要がある時の手。FPGA のコアで走るものは mruby bytecode のままでよい

**gem の決まり:** PicoRuby の gem の mruby ソースコード (mrblib) はそのまま使う (書き直さない)。PicoRuby で C の所だけを mruby ソースコードで書き
(`fpga/gems/`)、コアで走らせる。回路にするのは mruby ソースコードでは用をなさない (遅すぎて周期に間に合わない、など) と測って分かった時だけで、理由を書く。

**作り:** 段の順は今までと同じ (spec → 参照 ref_vm.rb → oracle → RTL、テスト・fuzz・docs は同じ commit)。
各段の頭に「変える意味 → 直す test と表」を書き出してから手を付ける (P8 までの後追いの反省。handoff 2026-09-27)。

**前提:** 直前の段は P8 (f55ae50)。gap は範囲内 71、変換を通る 66、一致 66、止まる 5。
`test:fpga` は 19 分 (gen_pkg_test 1162 秒、ref_vm_test 41 秒、rom_test 14 秒。他は 2 秒以下)。CPU は 4。

---

## Q 並列化 (最初にやる)

遅い所と、何が直列か:

| 所 | 今 | 遅い理由 | 並列にするもの |
|---|---|---|---|
| `test:fpga` の gen_pkg_test (`test_corpus_is_current`) | 1162 秒 | `FpgaCorpus.build_all` が 39 本を順に mrbc → picoruby の変換器 (1 本 約 30 秒) | 1 本ずつの compile + 変換 (外の process なので thread で足りる) |
| `rake fpga:corpus` | 同上 | 同じ `build_all` | 同上 |
| `test:fpga` のファイル | 11 本を順に | ruby を1本ずつ | テストのファイルごとに process |
| `fpga:check` | 39 本を順に | 参照 (Ruby コード、CRuby) + mrb_run_tb | 1 本ごと (fork。参照は GVL を離さないので thread では速くならない) |
| `fpga:gap` | 116 本を順に | mrbc + 変換器 + 参照 + sim | 1 本ごと (fork) |
| `fpga:fuzz` | 300 本を順に | 参照 + sim | 1 本ごと (fork)。**program は親で順に作る** (seed ごとの program の列は今と同じ) |
| `fpga:tb` | tb × {verilator, icarus} を順に | build と実行 | (tb, sim) ごと |
| `fpga:emu:check` | 39 本を順に | board_emu | 1 本ごと |

共有して壊れるもの (並列にする前に分ける):

- `build/fpga/fuzz/prog.hex`、`prog.stimsrc` と、`fpga_sim_trace(name: "fuzz" / "gap")` の `build/fpga/rom/fuzz.*`、`gap.*` → 1 本ごとの名前
  (`fuzz_<i>`、gap は program の相対 path から作る名前)
- `fpga_runner` (`build/fpga/verilator/mrb_run_tb*` を `rm_rf` して build) → worker を起こす前に親で build する。fork した子は memo を持って出る
- 同じ worktree で rake の fuzz / gap / check を2つ同時に走らせない、は変わらない (build の dir を取り合う)。1つの rake の中で並列にする

### Q1 並列の道具

**Files:** 新規 `tools/fpga/parallel.rb`、`tools/fpga/parallel_test.rb`

- [x] `FpgaParallel.map(items, jobs: FpgaParallel.jobs) { |item| ... }`: fork で `jobs` 本の子を起こし、結果を Marshal で pipe から返す。
  **返す順は items の順** (出力を今と同じ並びにするため)。子の例外は親で同じ message の例外にする (黙って落とさない)。
  `jobs == 1` なら fork しない (今と同じ動き。調べる時に使う)
- [x] `FpgaParallel.threads(items, jobs:)`: 外の process を待つだけの所 (mrbc、変換器) 用の thread 版。順と例外は同じ
- [x] `jobs` は環境変数 `FPGA_JOBS`、無ければ `Etc.nprocessors`。macOS と Linux の両方で動く (fork は両方ある)
- [x] test: 順が保たれる、子の例外が親に来る、`jobs: 1` で fork しない、空の items
- [x] 確かめ方: `ruby tools/fpga/parallel_test.rb`

### Q2 corpus の build (gen_pkg_test、fpga:corpus)

**Files:** `tools/fpga/corpus.rb` (`build_all`)

- [x] `build_all` の `sources.to_h` を `FpgaParallel.threads` にする。1 本ごとの tmpdir は今も別
- [x] 確かめ方: `rake fpga:corpus:check` が並列前と同じ (生成物の bytes が同じ = 差分なし)。gen_pkg_test の秒数を記録に書く

### Q3 test:fpga のファイル

**Files:** `rakelib/fpga.rake` (`test:fpga`)

- [x] テストのファイルごとに process を起こして並列に回し、出力はファイルごとにまとめて順に出す。1 本でも落ちたら落ちたファイルの名前を並べて rake を止める
- [x] 確かめ方: 失敗 0 の数 (runs、assertions) が並列前と同じ。わざと1本落とすと rake が止まり、その名前が出る

### Q4 check、gap、emu:check、tb

**Files:** `rakelib/fpga.rake`

- [x] check: 1 本ごと (参照 + sim + compare) を `FpgaParallel.map`。`ok ...` の行は今と同じ順で出す
- [x] gap: `FpgaGap.check` と参照・sim を 1 本ごとに。sim の name を program ごとに
- [x] emu:check: 1 本ごと。board_emu の build は親で先に
- [x] tb: (tb, sim) ごと。icarus の出力先が tb ごとに分かれているか確かめてから
- [x] 確かめ方: check の 39 行、gap の数と blocked の表、emu:check、tb の PASS が並列前と同じ

### Q5 fuzz

**Files:** `rakelib/fpga.rake` (`fpga:fuzz`)

- [x] 親で `count` 本の program (words、max、stim、heap) を今と同じ rng の順に作る → 子で参照と sim → stats と endings を親で足す
- [x] 違ったら、今と同じく **最初の番号の** 違いを `fail_seed<seed>_<i>.*` に残して止める
- [x] 確かめ方: seed 1–4 の要約の行 (halt / error / step limit / GC / reached) が並列前と1字も違わない

### Q6 host 側の AOT (spinel + suppify。Q2〜Q5 の後に測って決める)

道具と実績: [spinel](https://github.com/matz/spinel) (Ruby の AOT コンパイラー、C を出す) と
[bash0C7/suppify](https://github.com/bash0C7/suppify) (spinel で compile できるコードを C のライブラリにし、
`-t cruby` は CRuby の拡張 gem、`-t picoruby` は PicoRuby の mrbgem にする)。R2P2-ESP32 で `picoruby-otmeiwa_aot`
を実機の ELF に入れた実績がある。spinel は `spinel.pin` の commit に合わせる。
制約 (suppify の README): top-level のメソッドだけ、自作のクラスは不可、型は RBS (sidecar か inline) で全部書く。

対象は host で走る遅い所だけ。FPGA のコアで走るものは対象外 (mruby bytecode のまま):

| 遅い所 | 何か | AOT の形 |
|---|---|---|
| 変換器 (`isa` `io_map` `rite` `rom` `mrb2rom`) | mruby ソースコード、host の picoruby で走る。1 本 約 30 秒 | 熱い所 (命令の decode、表の組み立て) を top-level の型付きメソッドに切り出し、`suppify -t picoruby` の mrbgem を host の picoruby の build に足す (build_config の overlay。vendor/picoruby は commit しない) |
| 参照インタプリタ `ref_vm.rb` | Ruby コード、CRuby で走る。check / gap / fuzz で毎回 | 命令の実行の芯を切り出し、`suppify -t cruby` の拡張 gem |

- [ ] Q2〜Q5 の後に、どこで時間を食っているかを測る (変換器は picoruby の中の段ごとの時間、ref_vm は CRuby の profiler)。
  並列化で足りていれば Q6 はやらず、理由を記録に書く
- [ ] 切り出す前に、切り出すメソッドの入出力 (Integer、String、Array、Hash) を表にして、spinel が型を付けられるか確かめる
- [ ] 確かめ方: 置き換える前に、元の版の出力を取っておく (変換器は commit 済みの corpus の生成物、ref_vm は check / gap / fuzz seed 1–4 の出力)。
  AOT 版で同じものを作り、変換器は `rake fpga:corpus:check` が bytes で同じ、ref_vm は出力が1字も違わないことを確かめる
- [ ] 確かめたら**元の版は消して AOT 版だけにする**。二つを並べて残さない、環境変数での切り替えも作らない。
  戻す手段は git の commit だけ: 置き換えは「変換器」「ref_vm」でそれぞれ1 commit (AOT 版を足す・元を消す・rake とテストを直すを同じ commit)
  にし、`git revert <commit>` 1つで元に戻るようにする
- [ ] build の手順 (spinel の build、`SPINEL` / `SPINEL_LIB`) を `rake fpga:doctor` / `fpga:setup` に足す。macOS と Linux の両方

### Q の終わり

- [ ] `rake fpga:test` の時間を記録に書く (前: test:fpga だけで 19 分)
- [ ] spec §10 に「並列 (FPGA_JOBS)」、CLAUDE.md の注意書き (同じ worktree で同時に回さない) はそのまま
- [ ] commit `fpga: run corpus, tests, check, gap, fuzz and tb in parallel (FPGA_JOBS)`

---

## P9 picotest

調べて分かったこと: `runner.rb` の `Picotest::Runner` は **CRuby 側の係** (テストのファイルを探し、一時スクリプトを作り、
target の VM を spawn する。`Dir`、`File.open`、`posix-io` を使う)。板の上で走るのは `picotest/test.rb` と `double.rb` と、
テストのファイル (my_test.rb、my_2_test.rb) の方。

| 変える意味 | 直す test と表 |
|---|---|
| PicoRuby の `picotest/test.rb` と `double.rb` をそのまま使う。足りない C の所 (metaprog など) があれば、その所だけ `fpga/gems/` に mruby ソースコードで書く | `FpgaCorpus::GEMS` に picotest、gap_test |
| テストのファイルは Test の子クラスを定義するだけ。gap で走らせる時は、定義された子クラスを全部走らせる末尾 (Runner が target に渡すのと同じ呼び方) を付ける | gap.rb、gap_test |
| `runner.rb` は gap で「host 側の係 (CRuby で走る)」として範囲の外にする。理由を gap の表に出す | gap.rb の out_of_scope、gap_test |
| `File.dirname` / `File.expand_path` は作らない (runner の外で使う所が無い) | なし |
| `assert_raise` は例外 (P4) の上で動く。`instance_variable_get` などの metaprog が要れば P7 の send の上に足す | ref_vm_test、rom_test の許可表 (足す命令があれば) |

- [ ] oracle: host の picoruby で my_test.rb、my_2_test.rb を picotest の Runner から走らせた出力と、コアのコンソールを比べる
- [ ] コーパス `fpga/corpus/picotest.rb` (成功・失敗・例外の assert を全部)
- [ ] 確かめ方: gap で 3 本が match か範囲外 (理由あり)、fuzz seed 1–4、check、tb

## P10 pitchdetector

| 変える意味 | 直す test と表 |
|---|---|
| mrblib (`Note#freq_to_note` など) はそのまま。C の `detect_pitch` (pitchdetector.c: ADC の標本を溜めて自己相関) だけを `fpga/gems/` に mruby ソースコード (Float、P5b) で書く。標本は ADC (P5c) から。mruby ソースコード版で1回の検出の時間をコアで測り、`sleep_ms 10` の周期で用をなさなければ積和だけを回路 (デバイスのレジスタで起動・結果を読む) にし、mruby ソースコード版と一致させる | `FpgaCorpus::GEMS`、gap_test |
| `Signal.trap(:INT)` の扱いを決める (コアに Signal は無い。何もしない gem か、止める理由のまま) | gap の表 |
| ADC の刺激 (stim) に正弦波の標本を入れる。エミュレーターにも同じ波を入れられるように | compare.rb の stim、emu |

- [ ] oracle: pitchdetector.c と、CRuby で走る Ruby コードに写した計算を同じ標本で比べる (周波数と音名)
- [ ] コーパス `fpga/corpus/pitch.rb` (440 Hz、既知の音をいくつか)
- [ ] 確かめ方: tuner.rb が match、check、fuzz、tb

## P11 pio

PERIDOT-Air に RP2040 の PIO は無いが、FPGA なので PIO 相当の回路を作れる。user の指示 (全部やる) に従い範囲に入れる。

| 変える意味 | 直す test と表 |
|---|---|
| `PIO.asm` (アセンブラー) は mrblib の mruby ソースコードをそのまま (block の中の `out` `jmp` `label` `nop` `wrap` などは instance_eval) | P7 までで足りるか確かめる。足りなければ instance_eval を足す (ref、RTL、rom_test の許可表) |
| `PIO::StateMachine` はデバイスのレジスタ (io_map.rb に PIO の区画: 命令メモリ 32 語、SM の設定、TX FIFO) | io_map、gen_pkg (mrb_pkg.sv)、devices.rb、mrb_dev.sv |
| RTL の PIO: 状態機械 1 つから (sk6812 が使う out / jmp / nop / side-set / wrap / autopull / clkdiv)、その後に残りの命令 (in / push / pull / mov / irq / wait / set) | 新しい tb `mrb_pio_tb.sv`、ref の PIO モデル |
| トレースに PIO のピンの変わり目を出し、エミュレーターは WS2812 の波形を LED の色にデコードする | displays.rb か新しいデコーダー、emu |

- [ ] oracle: RP2040 の PIO の命令の意味 (データシート) を ref の PIO モデルに写し、RTL と cycle で比べる。sk6812.rb の色の列は CRuby で走る Ruby コードで計算した答えと比べる
- [ ] 確かめ方: sk6812.rb が match、tb 両シミュレーター、check、fuzz (PIO のレジスタを突く断片を足す)

## P12 host の picoruby との突き合わせを広げる

- [ ] 今は tasks / sends / int64 だけ host の picoruby と比べている。コーパスの全部を host で走らせ、コンソールの出力が同じか見る道具
  (`rake fpga:host` 相当。scratchpad の hostcmp.rb を tools/fpga に上げる)。違いは「表し方の違い」か「コアの違い」かを表にして、コアの違いは直す
- [ ] example の範囲外 45 本の理由を見直し、FPGA で作れるデバイス (P11 と同じ考え) があれば段にする

---

## 各段の終わりにやること (変わらない)

- `rake fpga:test` (並列)、`rake fpga:gap`、fuzz seed 1–4
- 計画 (2026-09-26 の方) の「記録」に1行、「見つけたこと」に書く
- commit は `fpga: ...`、push

## 記録

| 日付 | 段 | 結果 |
|---|---|---|
| 2026-09-27 | Q1〜Q5 並列化 | CPU 4。`fpga:corpus:check` 1162 秒 → 311 秒。`fpga:test` 全体 1345 秒 (tb の Icarus で peridot_air_top を compile する所が 17 分ほどで一番長い)。check 39 行、gap (71 / 66 / 66 / 5)、fuzz seed 1–4 の要約は1本ずつ回した時と1字も違わない |

## 見つけたこと

- Q: 変換器を `picoruby isa.rb,io_map.rb,rite.rb,rom.rb,mrb2rom.rb` と `,` でつないで走らせていたが、PicoRuby は file ごとに別の task
  にして同時に走らせる (picoruby.c の [tasks])。1本ずつ回していた時はたまたま順に終わっていただけで、並べて CPU が混むと
  `uninitialized constant FpgaIsa::CLASSES` で落ちた。mrbc で1つの .mrb (書いた順に1つの irep) にして渡すように直した
- Q: gap の hex は basename で `build/fpga/gap/` に書いていた。example には同じ basename のものがあり、並べると取り合う。path から名前を作る
- Q: 並べた後に一番長いのは tb の Icarus の compile (peridot_air_top_tb)。1 本の中の仕事なので並べても縮まない
