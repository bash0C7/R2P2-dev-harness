# FPGA × mruby ネイティブ CPU: コアと道具立て — 設計

元issue: 親 [#4](https://github.com/bash0C7/R2P2-dev-harness/issues/4)、子 [#6](https://github.com/bash0C7/R2P2-dev-harness/issues/6) [#7](https://github.com/bash0C7/R2P2-dev-harness/issues/7) [#8](https://github.com/bash0C7/R2P2-dev-harness/issues/8) [#9](https://github.com/bash0C7/R2P2-dev-harness/issues/9) [#10](https://github.com/bash0C7/R2P2-dev-harness/issues/10) [#11](https://github.com/bash0C7/R2P2-dev-harness/issues/11)

シミュレーション環境 (#5) は [2026-09-26-fpga-sim-env-design.md](2026-09-26-fpga-sim-env-design.md)。
仕様の正本は [docs/spec.md](../../spec.md) §10。ここには各 issue の「未決の問い」をどう決めたかを残す。

## 決め方

user から「中断不要、すすめろ」と指示があったので、各 issue 本文の「推奨」をそのまま採った。
推奨が無い問いは、6k LE と「まず動く」を優先して決めた。どれも後から変えられる形にしてある。

## 決定事項

| issue | 問い | 決定 |
|---|---|---|
| #6 | 整数の幅 | 32bit で折り返す。範囲外は仕様外 |
| #6 | 値の型タグ | 2bit (nil / false / true / Integer) + 32bit。段階 C で 3bit (+ Array / Proc、ヒープの中だけの転送先と見出し) |
| #6 | 命令の範囲 | コーパス駆動 (`fpga/corpus/*.rb`)。出現した命令と、同じ族で回路がほぼ増えないもので 38 命令 |
| #6 | compiler の版 | `SUBMODULE_PINS` の mruby-compiler に固定。コーパスの生成物を commit し、`fpga:corpus:check` で版のずれを検出 |
| #6 | irep | 1つだけ。子 irep・pool・catch handler は変換時に止める |
| #7 | ROM の語長 | 1命令1語の固定長 48bit {op8, a8, b16, c16}。`LOADI32` の 32bit も b:c に収まる。ジャンプ先は変換器が絶対語アドレスにする |
| #7 | 置き場所 | `tools/fpga/` (既存の `tools/<target>/` に揃えた) |
| #7 | 変換器の言語 | **PicoRuby** (user の指示)。PicoRuby の host VM で走らせ、rake は起動と受け渡しだけ。PicoRuby と CRuby の共通部分で書き、同じ file を CRuby の参照インタプリタやテストも読む。picoruby の無い CI の fpga job のために、コーパスの ROM (`.hex` `.lst`) は commit する |
| #7 | シンボル | 変換時に I/O ポート番号へ解決。対応表は `tools/fpga/io_map.rb` |
| #8 | 多サイクルかパイプラインか | 多サイクル (FETCH / EXEC の 2 cycle) |
| #8 | クロック | 実機の CLOCK_50 (50MHz) の単一クロック + クロックイネーブルで設計 |
| #8 | レジスタファイル | 16本固定。`nregs` > 16 は変換時に止める |
| #8 | 型エラー | 整数以外への算術・大小比較はエラー停止 (メソッド探索はしない) |
| #9 | 比べる粒度 | I/O の系列 (step 付き) と終わり方を合否に、トレース (X/W/O) は食い違いの場所探しに |
| #9 | 無限ループの打ち切り | 命令数の上限 (`fpga:check` は 20000) |
| #9 | 入力 | `<name>.stim` に step ごとの値。参照とシミュレーションで同じ step に効く |
| #9 | 参照インタプリタの正しさ | CRuby (`trace_var`) の出力系列と、picoruby host VM の最後の値 |
| #10 | Quartus の版 | 決め打ちしない。`quartus_sh` をそのまま呼ぶ |
| #10 | VM との受け渡し | `FPGA_QUARTUS_HOST` へ rsync + ssh。`quartus_sh` が PATH にあればローカルで |
| #10 | SRAM と EPCQ16 | まず SRAM (`openFPGALoader` で `.svf`)。EPCQ16 への永続書き込みは後 |
| #11 | 待ち時間 | CPU をクロックイネーブルで遅く回す (`CE_DIV`、既定 1000)。タイマー I/O は後 |
| #11 | `$BUTTON` | `D[0]` (PIN_84) に外付けスイッチ。内部 pull-up、GND に落とすと 1 |
| #11 | リセット | 基板のリセットスイッチ (`RESET_N`) をコアのリセットに |

## 確かめたこと・確かめていないこと

- シミュレーション (Verilator 5.020 / Icarus 12.0) では、命令ごとのテスト、コーパス5本の参照との一致、
  PERIDOT-Air の top (クロックイネーブル・LED・ボタン・リセット) まで green
- 変換器はコーパス全部で `mrbc -v` と1命令ずつ一致。参照インタプリタは CRuby と picoruby host VM に一致
- **Quartus での合成、LE / メモリの使用量、実機での点滅は未確認。** Quartus・PERIDOT-Air・USB-Blaster が
  この環境に無い。LED の点灯極性も未確認
- Mac での実行は未確認 (Linux のみ)

## 残り

- #10: Quartus を入れた VM (か x86 機) で `rake fpga:build[fpga/corpus/blink.mrb]` を通す。合成が SV の書き方で
  落ちたら直す (`always_ff` の配列リセット、untyped `parameter ROM_FILE` の文字列比較などが候補)
- #11: USB-Blaster で `rake fpga:flash`、LED の目視、fit summary の LE / メモリを spec §10 に記録
- 後回しにしたもの: パイプライン、レジスタファイルと ROM・ヒープの BRAM 化、EPCQ16 への永続書き込み、
  文字列・Hash・Range、Proc が作ったフレームより長生きする時の退避

## シミュレーターで完全に動かす (実機は後回し、user の指示)

段階 A (済): `def` したメソッド (再帰、途中の return)、定数、`*` `/` `%`、組み込みメソッド (`%` `!=` `-@` `<<` `>>` `&` `|` `^` `~` `!`
`abs` `zero?` `even?` `odd?`)。呼び出しはレジスタ窓 + コールスタック、呼び出し先は変換時に静的に解決。
差分ファズ (`rake fpga:fuzz`) で参照とコアのトレースが全行一致することを確かめる。

段階 B (済): ブロック。変換器が `times` / `upto` / `downto` / `loop` をカウンタのループとブロックの irep の呼び出しに展開し、
ブロックのフレームを呼んだフレームから静的な距離に置くことで、外側の変数を「bp から下へ何本目」にした。
コアに足したのは `GETUPVAR` `SETUPVAR` `BREAK` だけ。ブロックを値にすること (`proc` `yield` `&blk`)、`each` は対象外。

段階 C (済、user の「全部必要だ。全部やれ」): Proc・配列・時間待ち。

- **タグを 3bit にし、Array / Proc をヒープ (2048 語) の参照にした。** GC は Cheney のコピー GC (半分ずつ)。
  根を写す順を参照インタプリタとコアで揃え、GC の後のアドレスまでトレースで一致させる
- **ブロックは Proc になった。** Proc は作ったフレームの bp と、そのフレームの Proc (外側への鎖) を持つ。
  `GETUPVAR` の深さは鎖をたどって解く (段階 B の「静的な距離」をやめた)。`yield` / `&blk` / `block_given?` / `proc` /
  `lambda` / `.call`、`break` (iterator の出口へ、または Proc を作ったフレームまで)、ブロックの中の `return` (`RETURN_BLK`)
- **iterator は変換器がループに展開したまま。** `each` / `each_with_index` / `map` を足した
- **配列:** `ARRAY` `ARRAY2` `GETIDX` `GETIDX0` `SETIDX` と組み込み (`size` `length` `empty?` `first` `last` `pop` `push` `include?` `<<`)
- **時間待ち:** `sleep_ms` / `sleep` は `ms_tick` (1ms ごと、`MS_CYCLES` から作る) を数える。参照インタプリタは待たずに n を返す
- **差分ファズに GC まで届く形を足した** (4本に1本)。300 本で GC は 245 回起きる
