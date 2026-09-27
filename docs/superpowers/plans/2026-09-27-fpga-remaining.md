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

- [x] Q2〜Q5 の後に、どこで時間を食っているかを測る (変換器は picoruby の中の段ごとの時間、ref_vm は CRuby の profiler)。
  並列化で足りていれば Q6 はやらず、理由を記録に書く → **AOT はやらない** (記録と見つけたことを見る)
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

板の上で走るのは、Runner が作るスクリプト (`require 'picotest'`、テストのファイル、`my_test.test_x` の呼び出しを並べたもの、
最後に `puts "----"` と `JSON.generate(my_test.result)`)。picotest・json・env を GEMS に足して、この形のスクリプトを gap にかけると、
止める理由は次のとおり (scratchpad の probe で実測)。

| 止める理由 | 出どころ | 変える意味 | 直す test と表 |
|---|---|---|---|
| GEMS に無い | picotest、json、env | picotest (`picotest.rb`、`picotest/test.rb`、`picotest/double.rb`)、json (`json.rb`) は PicoRuby の mrblib をそのまま。env は mrblib の `env.rb` と、C の `_hash` だけ `fpga/gems/env.rb` (板に環境変数は無いので空の Hash) | corpus.rb の GEMS、gap_test |
| `require_relative` | picotest.rb の CRuby 側の枝 | `require` と同じく compile の時に解く (FPGA 版の gem が無いものは止める理由) | gap.rb、rom.rb の require の扱い、gap_test |
| `byteslice`、`strip!` | json.rb | プレリュードの String に足す (CRuby と host の picoruby の両方と比べる) | corpus の strings.rb、ref_vm_test |
| `methods` | double.rb の mruby/c の枝 | プレリュードの `Object#methods`: シンボル表を順に見て、受け手が応えるものを返す (`__sym_at`、`respond_to?`) | corpus の objects.rb、ref_vm_test |
| `alias_method` | test.rb (`alias_method :mruby?, :picoruby?`)、double.rb の mruby/c の枝 | 引数がシンボルのリテラルなら変換器が `alias` と同じく静的に解く。そうでなければ実行時に NotImplementedError (メソッド表は ROM) | rom.rb、rom_test、gap.rb の ALIAS の扱い |
| `caller` | test.rb の `report` (`caller(2, 1)`)、double.rb | 下の「caller の設計」 | isa、ref、RTL、rom、tb、fuzz |
| `` ` `` | test.rb の `run_script` | 板にプロセスは無いので NotImplementedError (`fpga/gems/` の picotest の C の所) | gap_test |
| `_alloc`、`define_method`、`define_method_any_instance_of`、`remove_singleton` | double.rb の C の所 (stub / mock) | メソッド表は ROM にあり、実行時にメソッドを足せない。この段では NotImplementedError にし、動的なメソッドの定義は別の段 (P9b) にする | gap_test |

**caller の設計** (mruby の `mrb_f_caller` / backtrace.c と同じ意味):
- 各フレームについて「そのフレームで今実行している命令の行」と「そのフレームのメソッド名」を `"<file>:<line>:in <method>"` にする。
  一番外 (main) は `"<file>:<line>"`。`caller(start = 1, length = nil)`、`caller(0)` は caller を呼んだメソッドのフレームから
- 行とファイル: corpus と gap は `mrbc -g` で compile し (命令の列は変わらない。DBG の section が付く)、rite.rb が DBG の section
  (packed_map) を読む。変換器は `caller` が生きている時だけ、呼び出しの命令 (SEND 系) の ROM の pc ごとに {pc, 行, ファイルのシンボル,
  メソッドのシンボル} の表を ROM のデータに置く (pc の順)。ファイル名はシンボルにする (Symbol#to_s で文字列に)
- コア: 命令 `FRAMEPC` (`__frame_pc(k)`: k 番目のフレームの呼び出しの pc。無ければ nil) と `ROMW` (`Integer#__rom_word`: ROM の
  データの語) を足す。プレリュードの `caller` が `__frame_pc` で pc を集め、表を二分探索して文字列にする
- 表の場所 (先頭と本数) は、main の最初にプレリュードの定数へ入れる (変換器が置く)

P9 の中身は WIP commit (cace315) に入った。済んだもの: 上の表の全行 (GEMS、require_relative、byteslice / strip!、methods、
alias_method、caller、`` ` ``、double.rb の C の所は NotImplementedError)、corpus の picotest.rb / caller.rb が host の picoruby と全行一致、
test:fpga、check、emu:check、tb の mrb_core_tb (両シミュレーター)。

### P9 の仕上げ (compact の後に計画し直し)

| やること | 確かめる値 (先に決める) | 通らなければ |
|---|---|---|
| fuzz seed 1–4 を1本ずつ順に (`rake fpga:fuzz[300,N]`) | 4 本とも mismatch 0。要約の `frame_pc`・`rom_word`・`truncate` がどの seed でも 0 でない。`frame_pc` は断片の中のブロックと maker のメソッドから呼ぶので、深さ 1 以上の値 (0 と nil 以外) が出る | 断片 (fuzz.rb の pick 26) を直し、直した理由を「見つけたこと」に書いてからもう一度 |
| gap | 範囲内 72 (71 + corpus の picotest.rb。注釈の語で範囲外にされていたもの)、変換 70、一致 70、止まる 2 (pio、pitchdetector)。範囲外の理由に "host side" が runner.rb の1本だけ | 数が違えば、どの program かを gap の出力で見て、判定の条件 (下の「gap の判定」) のどれに当たるかを書いてから直す |
| `rake fpga:tb` の全部 | 全 tb が Verilator と Icarus の両方で PASS | 落ちた tb を1本だけ回して直す |
| 記録と commit | 計画の P9 の行、記録に1行、commit `fpga: P9 picotest and caller, finish` を WIP commit (cace315) の上に積んで push (計画の commit 5e0ad35 が間に入ったので書き直さない) | — |

**gap の判定 (P9 の時点):** 範囲外 = (1) 板に無いハード (`HARDWARE` の表)、(2) host 側の係 (`HOST_SIDE_CONSTS`: `Picotest::Runner`。
注釈の行を除いてから探す)。範囲内で止まる = 変換器か GEMS が足りない。テストのファイル (`Picotest::Test` を継ぐクラスがある) は
Runner と同じ末尾を付けて走らせる。

## 全段で守ること (P9 で流してから直した反省)

- **段の頭に表を書く:** 変える意味 → 直す test と表 → fuzz がどの場合まで届くか (要約の stat の名前と、0 でないこと) →
  gap の数 (範囲内・変換・一致・止まる) の見込み。流してから表を直さない
- **ファイルを書き換える道具:** Edit か、Ruby コードの script ファイル (`ruby -Eutf-8`)。置き換えは `sub(old) { new }` の形
  (置き換えの文字列の `\0` `\1` を解かせない)。日本語を含むものを `ruby -e` に渡さない
- **重い rake (fuzz / gap / check / tb) は同じ worktree で1つずつ。** 長いものは nohup でログを scratchpad に、止める時は PID で

## P9b 動的なメソッドの定義 (picotest の stub / mock)

double.rb と double.c (src/mruby/picotest.c) を読んで分かったこと: stub / mock に要るのは次の4つ。

1. `Picotest::Double < BasicObject` と、未定義のメソッドが `method_missing(:名前, *引数, &blk)` に回ること
   (`stub(obj).foo { 1 }` の `foo` は Double の method_missing)
2. `_alloc(obj)`: BasicObject の子を作る (initialize を呼ばない)
3. `define_method(mid, obj)`: obj (または obj のクラス) にだけ効く `mid` を足し、中身は「`$picotest_doubles` を後ろから探し、
   `doubled_obj_id` (obj の object_id か、any_instance_of ならクラス) と mid が合う行の `return_value` を返す。mock なら
   `actual_count` を足す」。`define_method_any_instance_of(mid, klass)` はクラスに足す。`remove_singleton` で外す
4. `doubled_obj.object_id`: ヒープのオブジェクトの object_id (今は NotImplementedError。コピー GC で番地が動くため)

| 変える意味 | 直す test と表 |
|---|---|
| **BasicObject:** 組み込みのクラス BasicObject (番号を足す)。Object の親を BasicObject、BasicObject の親は無し。`==` `!` `!=` `equal?` `__send__` `instance_eval` `method_missing` だけ持つ (mruby と同じ)。プログラムのクラスが BasicObject を継げる | isa の CLASSES、rom.rb の表、ref、RTL (親の輪の終わり)、rom_test、corpus `basic_object.rb` (CRuby と host の picoruby で一致) |
| **method_missing:** 探索が見つからない時、同じ受け手のクラスで `:method_missing` を引き、見つかれば引数の前に `:名前` を入れて呼ぶ (レジスタを1つずらす。splat の形も)。無ければ今と同じ NoMethodError | ref、RTL (S_LOOKUP の失敗の先)、tb `method_missing`、fuzz、corpus `method_missing.rb` |
| **ヒープの object_id:** RAM の小さな表 (id の表、16 行) に {オブジェクトの番地} を置き、行の番号から id を作る。表は GC の根 (写すと番地を直す)。満ちたら RangeError (止める理由として文に書く) | ref、RTL (GC の根に足す)、tb、corpus `object_id.rb`、spec の §10 (1021 行の NotImplementedError を消す) |
| **上書きの表 (実行時のメソッドの定義):** RAM の表 (8 行) に {鍵 = object_id か クラス, シンボル, 飛び先}。探索は ROM の表より先に上書きの表を見る。飛び先は「その gem の mruby ソースコードのメソッド」で、method_missing と同じく `:名前` を前に入れて呼ぶ (double.c の `ci->mid` の代わり)。primitive `__override_set(鍵, mid, 飛び先の mid)` と `__override_clear(行)` | isa の PRIMS、ref、RTL、tb `override`、fuzz |
| **`fpga/gems/picotest.rb`:** `_alloc`、`define_method`、`define_method_any_instance_of`、`remove_singleton` と、中身の `__double_call(mid, *args)` (double.c の `mruby_method_missing_for_double` を mruby ソースコードに写したもの)。double.rb はそのまま GEMS に入れる | corpus.rb の GEMS、corpus `picotest_double.rb` (stub、mock、stub_any_instance_of、mock_any_instance_of、clear_doubles の後に元に戻る) |

- [ ] oracle: corpus の basic_object.rb / method_missing.rb / object_id.rb は CRuby と host の picoruby、picotest_double.rb は host の picoruby と全行一致
- [ ] fuzz の到達: 断片を足す (BasicObject の子への未定義の呼び出し → method_missing、`__override_set` した受け手への呼び出し、
  GC を挟んだ後の object_id)。要約の stat `method_missing`、`override_hit`、`objid_heap` が seed 1–4 のどれでも 0 でない
- [ ] gap の見込み: example に stub / mock を使うものは無い (grep で 0 本) ので数は P9 の仕上げと同じ。corpus が1本ずつ増える分だけ範囲内・一致が増える
- [ ] tb: 新しい case (method_missing、override、objid の GC 越え) を両シミュレーターで

## P10 pitchdetector

| 変える意味 | 直す test と表 |
|---|---|
| mrblib (`Note#freq_to_note` など) はそのまま。C の `detect_pitch` (pitchdetector.c: ADC の標本を溜めて自己相関) だけを `fpga/gems/` に mruby ソースコード (Float、P5b) で書く。標本は ADC (P5c) から | `FpgaCorpus::GEMS`、gap_test |
| 速さを測る: mruby ソースコード版で1回の検出の cycle をコア (tb) で数える。`sleep_ms 10` の周期 (125MHz で 1,250,000 cycle) に入らなければ、積和だけを回路 (デバイスのレジスタで起動・結果を読む) にし、mruby ソースコード版と一致させる。どちらにしたかと数えた cycle を spec に書く | 計画の記録、spec §10 |
| `Signal.trap(:INT)`: コアに割り込みのシグナルは無い。何もしない (block を覚えるだけ) gem にする。理由を spec に | `fpga/gems/signal.rb`、gap_test |
| ADC の刺激 (stim) に正弦波の標本を入れる。エミュレーターにも同じ波を入れられるように | compare.rb の stim、emu |

- [ ] oracle: pitchdetector.c を host で build したもの (host の picoruby に gem を入れる) と、FPGA 版を同じ標本 (440 Hz ほか 3 音) で比べる (周波数と音名)
- [ ] fuzz の到達: 回路にした場合だけ、積和のレジスタを突く断片 (stat `pitch_mac`)。mruby ソースコードのままなら fuzz は変えない
- [ ] gap の見込み: pitchdetector の example (tuner.rb) が一致に入り、止まる 2 → 1
- [ ] コーパス `fpga/corpus/pitch.rb`、check、tb

## P11 pio

PERIDOT-Air に RP2040 の PIO は無いが、FPGA なので PIO 相当の回路を作れる。user の指示 (全部やる) に従い範囲に入れる。

| 変える意味 | 直す test と表 |
|---|---|
| `PIO.asm` (アセンブラー) は mrblib の mruby ソースコードをそのまま (block の中の `out` `jmp` `label` `nop` `wrap` などは instance_eval) | P7 までで足りるか gap の止まる理由で確かめる。足りなければ instance_eval を足す (ref、RTL、rom_test の許可表) |
| `PIO::StateMachine` はデバイスのレジスタ (io_map.rb に PIO の区画: 命令メモリ 32 語、SM の設定、TX FIFO) | io_map、gen_pkg (mrb_pkg.sv)、devices.rb、mrb_dev.sv |
| RTL の PIO: 状態機械 1 つから (sk6812 が使う out / jmp / nop / side-set / wrap / autopull / clkdiv)、その後に残りの命令 (in / push / pull / mov / irq / wait / set) | 新しい tb `mrb_pio_tb.sv`、ref の PIO モデル |
| トレースに PIO のピンの変わり目を出し、エミュレーターは WS2812 の波形を LED の色にデコードする | displays.rb か新しいデコーダー、emu |

- [ ] oracle: RP2040 の PIO の命令の意味 (データシート) を ref の PIO モデルに写し、RTL と cycle で比べる。sk6812.rb の色の列は CRuby で走る Ruby コードで計算した答えと比べる
- [ ] fuzz の到達: PIO のレジスタ (命令メモリ、TX FIFO、SM の起動) を突く断片。stat `pio_write`、`pio_pin` が 0 でない
- [ ] gap の見込み: sk6812.rb が一致に入り、止まる 1 → 0
- [ ] tb 両シミュレーター、check

## P12 host の picoruby との突き合わせを広げる

| 変える意味 | 直す test と表 |
|---|---|
| 今 host と比べているのは tasks / sends / int64 / picotest / caller だけ。corpus の全部を host の picoruby (tools の VM) で走らせ、コンソールの出力を比べる `rake fpga:host` (FpgaParallel.map) | tools/fpga/host.rb、host_test、rakefile |
| 違いを表にする: 「host に無いデバイス」(GPIO など、host では走らない → 比べない、理由を表に)、「表し方の違い」(浮動小数の桁など)、「コアの違い」(直す) | spec §10 に表 |
| example の範囲外の理由を見直す。FPGA で作れるデバイス (P11 と同じ考え) があれば段を足す | 計画に段を足す |

- [ ] 確かめ方: `rake fpga:host` の「コアの違い」が 0。fuzz と gap は変えない (見込み: 数は P11 と同じ)

---

## 各段の終わりにやること (変わらない)

- `rake fpga:test` (並列)、`rake fpga:gap`、fuzz seed 1–4
- 計画 (2026-09-26 の方) の「記録」に1行、「見つけたこと」に書く
- commit は `fpga: ...`、push

## 記録

| 日付 | 段 | 結果 |
|---|---|---|
| 2026-09-27 | P9 picotest と caller | fuzz seed 1–4 一致 (frame_pc 172 / 204 / 52 / 26、rom_word 195 / 203 / 63 / 152、truncate 22 / 56 / 24 / 109)。gap 118 本: 範囲内 72 / 変換 70 / 一致 70 / 止まる 2 (pio、pitchdetector)、host 側 1 (runner.rb)。tb 4 本が Verilator と Icarus で PASS。test:fpga 89 秒。corpus の picotest.rb と caller.rb は host の picoruby と全行一致 |
| 2026-09-27 | Q6 測って AOT はやらない | 変換器の遅さ (CRuby の 200 倍) は host のテストの VM の debug (ESTALLOC_DEBUG の est_free が n²) で、AOT の出番ではなかった。debug 無しの VM (`rake fpga:picoruby`) で collections 34 秒 → 1.6 秒、出力は bytes で同じ。`fpga:corpus:check` 311 秒 → 17 秒、`test:fpga` 約 19 分 → 51 秒。ref_vm は 1 本 1〜2 秒で、並べた後の check / gap / fuzz の長さはシミュレーションの側 |
| 2026-09-27 | Q1〜Q5 並列化 | CPU 4。`fpga:corpus:check` 1162 秒 → 311 秒。`fpga:test` 全体 1345 秒 (tb の Icarus で peridot_air_top を compile する所が 17 分ほどで一番長い)。check 39 行、gap (71 / 66 / 66 / 5)、fuzz seed 1–4 の要約は1本ずつ回した時と1字も違わない |

## 見つけたこと

- Q: 変換器を `picoruby isa.rb,io_map.rb,rite.rb,rom.rb,mrb2rom.rb` と `,` でつないで走らせていたが、PicoRuby は file ごとに別の task
  にして同時に走らせる (picoruby.c の [tasks])。1本ずつ回していた時はたまたま順に終わっていただけで、並べて CPU が混むと
  `uninitialized constant FpgaIsa::CLASSES` で落ちた。mrbc で1つの .mrb (書いた順に1つの irep) にして渡すように直した
- Q: gap の hex は basename で `build/fpga/gap/` に書いていた。example には同じ basename のものがあり、並べると取り合う。path から名前を作る
- Q: 並べた後に一番長いのは tb の Icarus の compile (peridot_air_top_tb)。1 本の中の仕事なので並べても縮まない
- Q6: host のテストの VM (PICORB_DEBUG) では picoruby-machine が ESTALLOC_DEBUG を定義し、est_free が解放のたびにヒープの全ブロックを
  たどる。生きているオブジェクトが多いと n² (生きている配列 4 万で `format` 8000 回が 0.14 秒 → 4.2 秒)。変換器は debug 無しの VM で走らせる
- Q6: picoruby.c は .mrb を走らせると、終わりに `mrb_read_irep` の irep を `mrc_irep_free` で解放してヒープを壊す (upstream の不具合)。
  debug の VM は est_free の検査が黙って飛ばすので見えず、debug 無しの VM で SEGV になって分かった。変換器は1つの .rb につないで渡す
- Q6: vendor の `rake all` は `vendor/picoruby/bin/` の symlink を最後に build したものへ向け替える。別の build_config を build する時は
  `INSTALL_DIR` を別の所にする (`rake fpga:picoruby`)
- P9: host の PicoRuby の `caller` は、debug 情報の無い irep (mrblib の gem) のフレームを飛ばして数える (backtrace.c の pack_backtrace)。
  picotest の `report` の `caller(2, 1)` は、Runner の形 (test_* を直接呼ぶ) では空で、JSON の `method` は null になる。
  コアもプログラムの .rb のフレームだけを数えるので同じ値になる
- P9: mrbc に複数の file を渡すと、一番外の irep は file ごとの区間を持つ (DBG の files の start_pos)。行の表は packed_map だけ
  (この mruby の debug.c は ary と flat_map を読まず -1 を返す)
- P9: `picotest.rb` は RUBY_ENGINE で枝分かれし、FPGA が通らない枝 (mruby/c) で posix-io・metaprog・dir を require する。
  GEMS の3つ目 (数えない require) で扱う
- P9: Ruby の `String#sub` の置き換えの文字列の `\0` は一致した全体になる (rite.rb の注釈の `"END\0"` を壊した)。
  ファイルを書き換える道具は `sub(old) { new }` の形を使う
- P9 の仕上げ: gap の見込み (変換 70) に対して 69。corpus の picotest.rb の `nil.no_such_method` が gap の「未定義のメソッド」に当たった。
  corpus でわざと未定義にする名前は `__` で始める決まり (errors.rb の `__no_such_method`、gap は `__` を数えない) に合わせた
