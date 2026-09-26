# FPGA mruby コア: PicoRuby のプログラムをシミュレーターで完全に動かす — 実装計画

**目標:** 実在の PicoRuby プログラムを、変換器 → CPU コア (シミュレーション) で最後まで動かす。
対象はハードウェアが要らない範囲の全部 (下の「範囲」)。user の指示: 「全部やる」が必須条件、途中で尋ねない、実機は後回し。

**設計:** [CPU コアと道具立て](../specs/2026-09-26-fpga-mruby-core-design.md)、[docs/spec.md](../../spec.md) §10

## なぜ計画が要るか (ここまでの反省)

段階 A〜C は「次に足りなそうなもの」を自分で選び、自分で書いたコーパス (14 本) で確かめてきた。
実在のプログラムで測ると、**PicoRuby の example 89 本のうち、変換を通るものは 0 本**だった (2026-09-26 時点)。
最初に止まる理由は文字列 (87 本が使う)。ほかに、シンボル (64)、`Foo::Bar` (56)、クラス定義 (17)・`.new` (79)、
`require` (74)、`puts` (63)、例外 (16)、インスタンス変数 (14)、Hash (10)。

また進め方も場当たりだった:

- RTL を先に書き、テスト (`rom_test` `ref_vm_test` の oracle) を後から合わせた
- ファズで GC を突く形は、実装が終わってから GC に届いていない (0 回) と気付いて足した
- ドキュメントは最後にまとめて直した
- Proc が作ったフレームより長生きする場合を「仕様外」として、黙って間違った値を返す穴を残した

## 範囲

**入れる (ハードウェアが要らないもの全部):** 言語の中核 (文字列、シンボル、クラス・モジュール・インスタンス変数・動的な
メソッド呼び出し、省略可能・キーワード・残りの引数、Hash、Range、`case`、例外)、`puts` などの出力、`require`、
ボードのピンに写せるデバイスのライブラリ (GPIO、PWM、ADC、UART は console)、`Task` (協調マルチタスク)。

I2C / SPI の周辺機器 (ssd1306 などの表示器、センサー) と、計算だけの gem (psg、midibase-mml、zlib、pitchdetector) も入れる。
gem の Ruby 部分はプログラムと一緒に変換し、C の部分は組み込みとして作る。

**入れない:** 無線と通信 (socket、net/*、DRb、cyw43、BLE、セルラー、DFU)、USB デバイス (usb/*、keyboard)、
TLS と暗号 (openssl、jwt、mbedTLS。C の mbedTLS の上にあり、無線が無ければ使い道も無い)、ファイルシステム、
コンパイラ (prism、sandbox)、ホストの CLI (optparse)。PERIDOT-Air に無線も USB デバイスも記憶域も無いため。
一覧は `tools/fpga/gap.rb` の `OUT_OF_SCOPE`。これらを使うプログラムは「範囲外」として数え、失敗には数えない。

## 進み具合の測り方 (最初に作る)

`rake fpga:gap` が、対象のプログラム (`vendor/picoruby/mrbgems/*/example*` の範囲内のものと `fpga/corpus/`) それぞれについて:

1. mrbc で `.mrb` にする
2. 変換器に通し、止まるなら理由 (命令・メソッド・pool など) を全部数える (最初の1つで止めない)
3. 通ったものは参照インタプリタとコアで走らせ、トレースが一致するか見る

を行い、「範囲内 N 本のうち、変換を通る本数・一致する本数」と、止まる理由の多い順を出す。
各段の最初と最後に数字を記録する (この file の「記録」)。**段の完了条件は、その段で名指ししたプログラムが一致すること。**

## 進め方の決まり (場当たりにしない)

1. **順序は 仕様 → 参照インタプリタ → oracle → RTL。** まず `ref_vm.rb` に入れ、CRuby と picoruby host VM の結果と
   一致させてから RTL を書く。RTL を先に書かない
2. **テストは機能と同じ commit で。** コーパスのプログラム、`mrb_core_tb` のケース、ファズの生成器の拡張を同時に入れる。
   ファズは新しい機能に届いていること (回数) を出力で確かめる
3. **ドキュメント (spec §10) も同じ commit で。**
4. **段ごとに commit して push、CI が green になってから次へ。**
5. **「仕様外」で黙って間違えない。** 扱えないものは変換時か実行時にエラーで止める
6. 段の途中で見つけた別の問題は、この file の「見つけたこと」に書いてから直す

## 段

### P0 土台

- `rake fpga:gap` (上)。範囲内・範囲外の分類と、止まる理由を全部数える解析
- **Proc の環境を退避する。** メソッドから戻る時、そのフレームを作った Proc が生きていれば、フレームのレジスタをヒープの
  env オブジェクトへ写し、Proc は env を指す (mruby の REnv と同じ)。今の「仕様外」の穴を塞ぐ
- **lambda の意味。** 引数の数を調べる、`return` は lambda から戻る
- `mrb_core.sv` (886 行) からヒープ (確保・GC・配列の操作) を `mrb_heap.sv` に分ける。以降の文字列・Hash もヒープの
  オブジェクトなので、先に境界を作る。分けた前後でトレースが全く同じことをコーパスとファズで確かめる

### P1 オブジェクトモデル

- シンボル (`LOADSYM`): 変換器が番号を振る。名前の表は ROM に置く (`inspect` / `to_s` 用)
- クラス・モジュール (`CLASS` `MODULE` `OCLASS` `DEF` `SDEF` `EXEC` `TCLASS` `LOADSELF` `RETSELF`)、`.new` / `initialize`、
  インスタンス変数 (`GETIV` `SETIV`)、`attr_reader` / `attr_accessor`、`super` (`SUPER`)、`include`、`is_a?` / `class` / `respond_to?`
- **動的なメソッド呼び出し。** 値に型 (クラス番号) を持たせ、変換器が作るメソッド表 (クラス番号, シンボル) → pc を ROM に置く。
  コアは表を引く (無ければ親クラス、それでも無ければ NoMethodError)。組み込みのメソッドは組み込みクラスの表に載せる
- 引数: 省略可能・残り・キーワード・ブロック (`ENTER` 全部、`ARGARY` `KARG` `KEY_P` `KEYEND` `APOST` `ARYCAT` `ARYPUSH`)
- `Foo::Bar` (`GETMCNST` `SETMCNST`)、`GETGV` の一般のグローバル変数
- 名指し: `fpga/corpus/` に classes.rb / args.rb、example から範囲内でこの段の機能だけで通るもの

### P2 文字列と出力

- 文字列はヒープのオブジェクト (4 byte / 語)。pool の文字列は ROM のデータ領域に置き、`STRING` が写す
- `STRCAT`、式展開 (`to_s`: Integer の10進変換)、`+` `*` `==` `size` `[]` `split` `to_i` `upcase` など、example に出るもの
- `puts` / `print` / `p` / `inspect` は console ポートに1文字ずつ出す。トレースは `C <step> <byte>`、テストベンチは文字列で表示、
  ボードエミュレーターは UART の TX として出す。`LOADL` (pool の整数)
- 名指し: hello.rb、式展開、example の文字列を使うもの

### P3 Hash、Range、case、Array の残り

- Hash (`HASH` `HASHADD` `HASHCAT`、`[]` `[]=` `each` `keys` `fetch` ...)、Range (`RANGE_INC` `RANGE_EXC`、`each`、`include?`)
- `case` / `when` (`===`)、`Array.new` `join` `each_slice` `sort` `select` `reject` `inject` など example に出るもの、`AREF` `APOST`

### P4 例外

- `raise` / `rescue` / `ensure` / `retry` (`EXCEPT` `RESCUE` `RAISEIF` `JMPUW`)。irep の catch handler を ROM の表にする
- コアの実行時エラー (0 で割る、NoMethodError、型の違い) を例外にし、`rescue` できるようにする。捕まえなければ今と同じく止まる

### P5 require とデバイス

- `require` は変換器が解決する。範囲内の gem は組み込み、範囲外は「範囲外」
- GPIO (`GPIO.new(pin, GPIO::OUT)`、`write` `read` `high?` `low?`)、PWM、ADC (シミュレーションの入力)、UART (console)、
  `Machine` の範囲内のもの。ボードの top のピンを増やし、エミュレーターに見せる

### P6 Task

- `Task.new { }`、`Task.pass`、`sleep` で切り替わる協調マルチタスク。タスクごとにレジスタ窓とコールスタックを持つ

## 記録

| 日付 | 段 | 範囲内 | 変換を通る | 一致 | メモ |
|---|---|---|---|---|---|
| 2026-09-26 | 開始時 | 46 (全 91、範囲外 45) | 14 (自作のコーパスだけ。example は 0 / 32) | 14 | 止まる理由: 文字列 24、`.new` 19、シンボル 16、`Foo::Bar` 14、`puts` 11 |

| 2026-09-26 | P0 env・lambda | 47 | 15 (example は 0 / 32) | 15 | closures.rb を追加。example はまだ文字列で止まる |

## 見つけたこと

- P0: 多重代入 (`a, b = make_counter(5)`) に `AREF` が要った (P3 の予定を前倒しで入れた)
- P0: `mrb_core_tb` の期待値を2回間違えた (BLKCALL のフレームが上のレジスタを nil で埋めること、R1 が最後に Proc になること)。
  どちらも参照インタプリタで同じ ROM を走らせて、RTL ではなくテストの誤りと確かめてから直した。
  テストベンチのケースは、先に参照インタプリタで期待値を出してから書く
