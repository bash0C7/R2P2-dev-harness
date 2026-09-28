# FPGA v2 の乖離表 (mruby / PicoRuby との違い)

[計画](superpowers/plans/2026-09-27-fpga-v2.md) の §4 の「違えるのは資源と回路の都合だけ」の一覧。**ここに無い違いは不具合**として扱う。
firmware の def、layout.rb の field、ref.rb の命令で C に対応が無いものは、`# C: none (D<nn>)` でこの行を指す (計画 S2 で `inventory_test` が確かめる)。
accept の範囲外 (`fpga/v2/accept/scope.tsv`) の理由も、この行に結ぶ。

- **正本:** mruby と PicoRuby の C と mrblib (`vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/`、各 gem)
- **基準の build:** host の PicoRuby (`build_config/fpga-tools.rb`、posix の baseline の profile)
- **FPGA が写す build:** PicoRuby の組み込みの build (`MRB_CONSTRAINED_BASELINE_PROFILE`)
- **状態の列:** 今ある (今の ref / firmware に入っている) / 予定 (その段で入れる) / 消す (その段で無くす)

## 表し方 (見える意味は変わらない)

| D | 違い | mruby の正本 | 理由 | 見える所 | 状態 |
|---|---|---|---|---|---|
| D01 | 値は 16 バイト {tag, 0, 上位 32bit, 下位 32bit}、big endian | `mrb_value` (MRB_NO_BOXING、value.h) | 32bit の語の記憶。`.mrb` と同じ向き | 無い | 今ある |
| D02 | ポインタは 32bit (host は 64bit) | 各 struct のポインタの欄 | SDRAM 32 MB に 25bit で足りる。回路の幅 | struct の大きさ、estalloc の見出しの大きさ、`GC.stat` のバイトの値 | 今ある |
| D03 | 固定長の枠は 64 バイト | `RVALUE` (gc.c) | D02 と、欄を 4 バイト境界にそろえるため | `GC.stat`、ObjectSpace の大きさ | 今ある |
| D04 | layout.rb の欄の並びは C の struct と未照合 (RString の embed が無い、RClass の ROM の欄など) | object.h、string.h、class.h ほか | — (照合していない) | 未照合 | 計画 S2 で `# C: struct` を付けて照合し、残る違いをこの表の行に分ける |
| D05 | メソッド表は開番地法で、値の下位 2bit に可視性 | `mt_tbl` (class.c)、`MRB_METHOD_VISIBILITY` | 回路の cache の外れで引きやすい形 | 無い (`methods` の順は S2 で host と照合) | 今ある |
| D06 | iv と定数の表は {数, 容量, 行の並び}、行は 20 バイト | `iv_tbl` (variable.c) | D05 と同じ形にそろえた | 無い (`instance_variables` の順は S2 で照合) | 今ある |
| D07 | シンボル表は FNV-1a の開番地法 (65,536 行)、番号 = 行の位置 | symbol.c、presym | 回路と firmware が同じハッシュで引く | シンボルの番号の値 | 今ある |

## 実行の仕組み (回路と firmware の分け方)

| D | 違い | mruby の正本 | 理由 | 見える所 | 状態 |
|---|---|---|---|---|---|
| D10 | 罠: 回路が終えられない命令と、メソッドの探索の外れは、firmware (mruby ソースコード) のメソッドを呼ぶ | vm.c の遅い道、C の関数 | C の代わりに、コアで走る mruby ソースコードで写す | 無い | 今ある |
| D11 | 罠の続きの情報を mrb_callinfo の後ろの延長の語に置く: 続きの種類 (0 普通の戻り、1 命令を進める、2 探索の罠の続きの SEND、3 結果を R[a] へ、4 起動、5 __fpga_run、6 キーワードの Hash を組んだ後の SEND (OP_SEND の hash_new_from_regs の後)、7 ブロックを Proc にした後の SEND (ensure_block の後))、a、n、sym、ret_pc、dst+1、fcall。罠のフレームの cci は CINFO_DIRECT。罠の窓は R[nregs+1] から (mruby-compiler の ensure が nregs に数えない R[nregs] を使い、C の関数はスタックを使わないので壊さない) | `mrb_callinfo` の `cci` | C は native のスタックで続きを持つ。回路には C のスタックが無い | 無い | 今ある (計画 S2b) |
| D12 | ci.n は 0〜14 はそのまま、15 以上は 15。回路は splat を窓に広げる (mruby は ENTER が広げる) ので、本当の引数の数は延長の語 argc に置く | vm.c の OP_SEND、`mrb_callinfo.n` | 窓に並べた方が回路が簡単 | 無い (ENTER の後の意味は同じ) | 今ある (計画 S2b) |
| D13 | 特権の primitive (`__fpga_*`) は回路が symbol で引く表で実行する | C の関数の直接の呼び出し | 記憶の生の読み書きなど、C でしかできない所 | 名前 `__fpga_` は予約 | 今ある |
| D14 | firmware だけの helper は名前を `__fpga_` にし、reflection (`methods`、`respond_to?`) から隠す。C で定義された `__x` (`__svalue` など) は普通のメソッド | C の static 関数 (見えない) | C の static 関数に当たる | 無い (隠せば) | 名前は S2-4 で `__fpga_` にそろえた。reflection (methods ほか) から隠すのは、それらを firmware に写す時 (計画 S5) |
| D15 | attr_reader / attr_writer は Proc の種類 (IVGET / IVSET) | class.c の attr (cfunc + env) | 回路で速く読み書きする | `Method#source_location` など (範囲外なら scope に書く) | 今ある |
| D18 | 起動の像の見出し (IMG) と組み込みのクラスの表 (CORE) は、番地の並べ方が自前。picoruby-machine の heap.c の static (picorb_heap_estalloc / start / end) も IMG の欄 (est_heap ほか、計画 S6-1) | `mrb_state` (include/mruby.h) | 起動の像の道具が作る | 無い | 今ある。**計画 S2b で `mrb_state` の形に置き直す** |
| D19 | Proc の入れ物のクラスは ci の target class だけで決める (mrb_vm_cref_class の cref の鎖と、class_eval などで与えられたクラス (MRB_PROC_GIVEN、MRB_ENV_SET_GIVEN_CLASS) は未写し) | proc.c の mrb_proc_new / mrb_method_proc_new / mrb_env_new | 計画 S4-1 ではブロックとメソッドの定義だけ | class_eval / instance_eval の中の def と定数 | 今ある。**S5 (class_eval、module_eval を写す時) に消す** |
| D17 | libc の関数 (memcmp など) を firmware の helper で書く | libc | firmware に libc が無い | 無い | 今ある |
| D16 | メソッドの cache を回路に持つ (組み込みの profile は `MRB_NO_METHOD_CACHE`) | class.c の method cache | 呼び出しの速さ | 無い (cache の消去が正しければ) | 今ある |
| D42 | mruby-array-ext の集合の演算 (`Array#-`、`#\|`、`#&`、`difference`、`union`、`intersection`、`intersect?`、`uniq` の `__uniq` / `__uniq!`) の ary_memb は、要素が多い時 (SET_OP_HASH_THRESHOLD 8 を超える) の khash の set を作らず、いつも配列を辿る (ary_elem_eql = mrb_eql) | mruby-array-ext の array.c の ary_memb_init / ary_memb_has / ary_memb_first / ary_memb_take | khash (khash.h) を firmware に写していない | 9 個以上の時に要素の `hash` が呼ばれない (結果は `hash` と `eql?` が合っていれば同じ) | 今ある。**khash を写す時 (S5 の Array か S6) に消す** |
| D61 | `==` を定義した印 (MRB_FL_CLASS_EQ_DEFINED) を子のクラスへ付ける eq_defined_walk の heap の走査をせず、nil / true / false のクラスだけ祖先を辿って付ける。firmware (像の中の def) の命令は bop_redefined を見ない | class.c の eq_defined_mark、vm.c の OP_ADD / OP_CMP / OP_EQ | bump の確保の heap は物を辿れない (GC は S6)。firmware は C の関数の写しで、C の演算子は再定義に従わない | 無い。heap の物の印は、回路が OP_EQ の同じ物の時に == を探して、見つかった Proc が起動の後のもの (bop_builtin の表より後の番地) かで答える (印は一度付けば消えないが、探索は == を消した後は付いていないと答える) | 今ある。heap の走査は S6 の gc.c の mrb_gc_each_live_object を写す時に |
| D50 | double の演算 (+ - * /、比べる、mrb_int との変換) を firmware の整数の演算の helper (`__fpga_f64_*`、fpga/firmware/float.rb) で行う (soft-float)。結果は IEEE 754 binary64 と同じ (最近接の偶数への丸め、非正規化数、無限大、NaN、符号付きの 0)。NaN の中身は x86 の SSE の決まり (左の NaN を quiet に、無効な演算は既定の NaN) | C の double の演算子 (numeric.c の flo_* ほか) | コアに浮動小数点の演算器が無い (資源) | 無い (NaN の中身は mruby が通し番号で上書きする。`tools/fpga/v2/softfloat_test.rb` が CRuby の double と libm とビットで比べる)。libm の pow (D17) は指数が整数の時だけ写し、最近接の偶数へ正しく丸める。glibc の pow はちょうど半分の所で違い得る (`10.0 ** 23` を host は 1.0000000000000001e+23、firmware は 1.0e+23)。整数でない指数は止まる | 今ある (S5f)。pow は glibc の e_pow.c を写す時に直す |
| D51 | fp_uscale.c の uint64_t の演算と 64bit × 64bit の積 (mul64) を helper (`__fpga_u64_*`、`__fpga_mul64`) で。pow10_tab (static const の表) は firmware の `__fpga_pow10_tab` の文字列の literal で、mrbc が行ごとに置く irep の pool を番地で読む | fp_uscale.c の `uint64_t`、`mul64`、`pow10_tab` | firmware の Integer は符号付きの 64bit で、+ - * の桁あふれは罠。C の表 (rodata) を置く所が無い | 無い | 今ある (S5f) |
| D63 | 配列を縮めても容量を縮めない (`delete_at`、`slice!`、`uniq!` などの後の ary_shrink_capa を写さない)。長い配列の `shift` は、C の共有の配列の L_SHIFT と同じく先頭の番地を進める (ary_make_shared は写さない) | src/array.c の ary_shrink_capa、ary_make_shared | 記憶を返す GC が無い (返しても使い道が無い) | 無い (容量は見えない) | 今ある |
| D64 | mruby-array-ext の `__product_generate` の生成器と `__combination_init` の状態 (Data_Make_Struct の RData) を Array で持つ ([total, cursor] と [mode, n, k, indices]) | mruby-array-ext の array.c の struct ary_product_generator、struct mrb_combination_state | RData (MRB_TT_CDATA と mrb_data_type) を firmware に写していない | 無い (mrblib の `product` と `__combination` の中だけで使い、外に出ない) | 今ある |

## 立ち上げの間だけの違い

| D | 違い | mruby の正本 | 理由 | 見える所 | 状態 |
|---|---|---|---|---|---|
| D40 | gem の mrblib (mruby ソースコード) のメソッドを firmware に仮に写す (Kernel#puts / print、picoruby-machine の IO を通す形でなくコンソールに直接) | picoruby-machine の mrblib と C | 計画 S7 で gem をそのまま像に入れるまで、programs と fuzz を走らせるため | 定義の場所 (`source_location` など)、`$stdout` を差し替えた時 | 今ある。mruby の mrblib の仮の写し (Numeric#-@) は S4-3 で消した。**S7 で消す** |
| D41 | backtrace を詰める時 (pack_backtrace)、firmware だけのフレーム (名前が `__fpga_` の helper と罠) を越え、像の中の Proc (firmware) のフレームを C の関数のフレーム (MRB_PROC_CFUNC_P) として扱う。行の表 (packed_map) は写さず .mrb の中を指す | backtrace.c の pack_backtrace、load.c の read_debug_record | firmware の helper と罠は C に ci が無い。C の関数を firmware のメソッドにしたので、そのフレームは ROM の Proc | attr の reader / writer は罠のフレームなので、frozen の writer の例外に `in x=` の行が出ない (C は cfunc のフレーム)。firmware に無い C のメソッド (method_missing になる) は行が出ない | 今ある |

## 記憶の管理 (計画 S6、設計 §6)

| D | 違い | mruby の正本 | 理由 | 見える所 | 状態 |
|---|---|---|---|---|---|
| D20 | GC の 1 step で 1 周を終える (止まる GC)。GC の本体は gc.c のとおり写し、駆動だけ `run_incremental(..., run_to_root)` | `incremental_gc`、`incremental_gc_step` (gc.c) | 根と sweep の誤りを barrier の抜けと分けて見つける | 止まる時間、`GC.stat[:state]` | 予定 S6-4。**S6-6 で incremental を写して消す** (S6 計画 §4 の条件に当たれば V3e) |
| D21 | minor GC 無し (host は generational が既定)。像は `generational = FALSE` で起動 | `mrb_gc_init`、`is_minor_gc` | generational は S6 の完了に入れない (S6 計画 §4) | `GC.generational_mode`、`GC.stat[:generational]` | 予定 S6-4。段 S6g で消す |
| D23 | `step_limit` を無視する (値は持つ) | gc.c `incremental_gc_step` | D20 | `GC.step_limit` | 予定 S6-4。S6-6 で消す |
| D24 | scheduler の `auto_step` / `debt_limit` | gc.c、mruby-task の src/gc.c | task の scheduler は S7 | `GC.scheduler_driven` | 予定 S7 |
| D25 | estalloc の firmware の写し (32bit の形) を、64bit の C の .so と Fiddle で比べる。戻りの番地は BPOOL_TOP からの差で比べる (違いは FREE_BLOCK の大きさ、top_adrs の位置、POOL_HEADER_SIZE だけで、calc_index と分割と結合は同じ)。32bit の build そのものは estalloc 自身の make に任せる | estalloc.c (`PLATFORM_64BIT`) | 64bit の CRuby は 32bit の .so を読めず、この環境の gcc に `-m32` が無い | 無い | 今ある (S6-1、`tools/fpga/v2/estalloc_test.rb`) |
| D26 | profile の違い: FPGA は constrained (heap page 128、`KHASH_INITIAL_SIZE` 16)、基準の host は baseline (1024) | `picoruby-mruby/mrbgem.rake`、mrbconf.h | FPGA は組み込みの build を写す | `GC.stat` の値 | 今ある (host は変えない) |
| D80 | firmware の Proc は像の中の RED (MRB_GC_RED) の物、irep は `MRB_IREP_STATIC`。ROM のメソッド表の層は辿らない (`mt_readonly_p`) | C の関数 (Proc でない、mrb_method_t の func) | firmware は C の関数を mruby ソースコードの Proc で写す (D10、D41) | 無い | 予定 S6-2 |
| D81 | VM のスタック (65,536 値) と ci の並び (4,096) は像の固定の領域で、stack_extend / cipush の realloc を写さない。`mark_context_stack` の nil の埋めは stend まで primitive `__fpga_fill` (memset、D17) で | vm.c `stack_extend`、`cipush`、gc.c `mark_context_stack` | スタックを動かすと窓 (回路の cache) と env の番地を付け直すことになる | GC の止まる時間 (埋めが 1 MB) | 予定 S6-4 |
| D82 | `mrb_vm_exec` と `mrb_funcall_with_block` の C の局所変数 `ai` を、C から点けたフレーム (`CINFO_SKIP`) と、C から名前で呼んだ C の関数 (罠でない `CINFO_DIRECT`) の延長の語 `CI_AI` (`ai + 1` と protect の bit) に置く。回路は今の ai をレジスタに持つ | vm.c `mrb_vm_exec`、`mrb_funcall_with_block`、`yield_with_attr` | 回路に C のスタックが無い (D11 と同じ) | 無い | 予定 S6-3 |
| D83 | firmware (C の写し) の中の命令が作る一時の物 (文字列と配列の literal、`__fpga_raisef` の引数の配列) は C に無い確保で、C の関数が戻るまで arena に残る | C の関数の中の確保 | firmware は mruby ソースコード | GC の回数、`GC.stat[:live]` の途中の値 | 予定 S6-3 |
| D84 | C の関数の自動変数 (struct と char の並び: index_buckets_iter、h_check_modified、数の文字列の buf) を、firmware は gc.c の `mrb_temp_alloc` で確保する | C のスタックの上の局所変数 | firmware に C のスタックが無い | `GC.stat[:live]` の途中の値、GC の回数 | 予定 S6-2 |
| D85 | 像が作る物 (組み込みのクラス、metaclass、iclass、top_self、表) は GC の始まる前の確保で、負債を数えない | `mrb_open` の中の確保 (`mrb_obj_alloc_core` の `gc_debt++`) | 像は起動の前に作る (D18) | `GC.stat` (D33) | 予定 S6-2 |
| D86 | estalloc の pool は `[heap_start, heap_end)`。mrb_state、シンボル表、VM のスタックと ci、`.mrb` は pool の外 | PicoRuby の `mrb_open_with_custom_alloc` (全部を est_malloc) | 像の固定の領域 (D07、D18、D81) | estalloc の統計 (used / total) | 予定 S6-2 |
| D87 | stress: 像の見出しの `gc_stress` (N) で N 回の確保ごとに `mrb_full_gc` (C の MRB_GC_STRESS は毎回で、N = 1 が同じ)。incremental の stress は確保ごとに 1 step。解放の埋めは MRB_DEBUG の道と estalloc の 0xaa / 0xff (ESTALLOC_DEBUG の走査は入れない) | gc.c `MRB_GC_STRESS`、estalloc.c `ESTALLOC_DEBUG` | ref が遅く、毎回の GC では回す範囲が狭くなる | 無い (検査の時だけ) | 予定 S6-5 |
| D88 | S6-2〜S6-3 は像が `gc.disabled` を立てて起動する (GC の本体がまだ無い) | `mrb_gc_init` | 段の途中 | `GC.enable` / `GC.disable` の戻り値 | 予定 S6-2、S6-4 で消す |
| D89 | シンボルの GC (`mrb_symbol_gc`、SYM_FL_DYNAMIC、MRB_SYMBOL_MAX 4096) を写さない | symbol.c | シンボル表の形 (D07) が違う | `GC.stat[:dynamic_symbol_count]`、65,536 を超えるシンボル | 予定 S6-4。D07 を直す時に消す |
| D90 | `obj_free` の `mrb_mc_clear_by_class` は、回路の method cache (D16) を全部消す | gc.c `obj_free`、class.c `mrb_mc_clear_by_class` | cache は回路にある (D16) | 無い | 予定 S6-4 |
| D91 | arena を 1 つ早く広げる (`arena_idx + 1 == arena_capa` で `gc_arena_keep` の realloc)。不変条件は「保存した ai はどれも `arena_capa` より小さい」 | gc.c `gc_arena_keep` | 回路の命令が途中で罠に落ちず、活性化の戻りの protect が確保を要らない | `arena_capa` の値だけ | 予定 S6-3 |
| D92 | `gc_drive` の `MRB_TRY` / `MRB_CATCH` (dfree の例外で `collecting` を戻す) を写さない | gc.c `gc_drive` | firmware に RData の dfree は無い。GC の中の例外は ref の `Error` | 無い | 予定 S6-4 |

## 範囲 (accept の範囲外の理由)

| D | 範囲外 | 理由 | 確かめ方 (accept.rb) |
|---|---|---|---|
| D30 | 板の上のコンパイル (irb、`.rb` の実行、`sandbox.compile`、文字列の `eval`) | user が決めた (2026-09-27)。host の mrbc で `.mrb` にして送る | assert の本文に `eval(` か `compile` がある |
| D31 | mruby-test の C の helper (`Mrbtest`、`AryShared`、`__env_*`、`TestVFormat`、`TestSysFail` など) | テスト用の C で、R2P2 の build に無い | assert の本文にその名前がある |
| D32 | 外の process (test/t/syntax.rb の backtick) | 板に process が無い | file が syntax.rb |
| D33 | profile に依る `GC.stat` の key と値 (`:state`、`:generational`、絶対の数)。`:live` の差は範囲内 | D02 D03 D20〜D26 | assert の本文に `GC.stat[:<key>]` がある (`:live` の差は除く) |
| D34 | RP2 にしか無いもの (PIO、USB CDC、BOOTSEL、WiFi / BLE) | PERIDOT-Air に無い | gem の名前 |
