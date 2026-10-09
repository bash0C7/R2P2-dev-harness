# FPGA のシミュレーション環境と rake fpga:* — 設計

元issue: [#5](https://github.com/bash0C7/R2P2-dev-harness/issues/5)（親 [#4](https://github.com/bash0C7/R2P2-dev-harness/issues/4)）

## 目的

ボードが無くても、SystemVerilog の回路と自己チェック型テストベンチを Mac と Linux で回して合否が出る状態にする。以後の FPGA 子issue（#6〜#11）はすべてこの上で進む。

## 決定事項（brainstorming で詰めた3つの問い）

| 問い | 決定 |
|---|---|
| rake タスクの形 | 両方持つ。`rake fpga:test` で全テストベンチ (後に `rake fpga:tb` へ改名し、`fpga:test` は CPU コアの突き合わせまで含む上位のタスクにした。docs/spec.md §10)、`rake fpga:sim[tb]` で1本（Verilator）、`rake fpga:sim:icarus[tb]` で1本（Icarus） |
| シミュレータの導入 | Mac でも Linux でも動かす。`rake fpga:setup` が macOS なら `brew install`、Linux なら `apt-get install -y`（root でなければ sudo）。`rake fpga:doctor` が有無と版を見る。Surfer は任意（Linux の apt には無いので入手先を表示するだけ） |
| CI | `.github/workflows/test.yml` に別 job `fpga` として載せる。picoruby の取得が要らないので host job と独立して軽い |

## 構成

- `fpga/rtl/**/*.sv`: 回路。全部を毎回コンパイルに渡す
- `fpga/tb/<name>_tb.sv`: テストベンチ。top module 名 = file 名
- `rakelib/fpga.rake`: rake タスク。`vendor/picoruby` に依存しない
- 生成物は `build/fpga/`（Verilator の Mdir、Icarus の `.vvp`、波形 FST）

## 合否の約束

- テストベンチは合格なら最後に `PASS <tb名>` を出して `$finish`、食い違えば `$fatal`
- rake は **exit status が 0 かつ `PASS <tb名>` 行がある** 時だけ合格にする（PASS 前に `$finish` した tb を合格にしない）
- Verilator は `--binary --timing --assert -Wall`。warning は error になる（Verilator の既定）
- Icarus は `-g2012 -Wall`、`vvp -n`
- `+dump=<path>` を渡した時だけテストベンチが FST を書く

## シミュレータの役割分担

- **Verilator（主）**: 速い。2値なので未初期化 register は 0 から始まり、リセット漏れを見逃す
- **Icarus（補助）**: 4値。リセット漏れが X として見え、`$isunknown` で落ちる
- `fpga:test` は両方で回す

## 完了条件（#5）

- `fpga/` に 8bit カウンタと自己チェック型テストベンチが1組ある
- `rake fpga:test` が green、わざと壊すと red
- 波形を Surfer で開く手順が README と docs/spec.md §10 にある
