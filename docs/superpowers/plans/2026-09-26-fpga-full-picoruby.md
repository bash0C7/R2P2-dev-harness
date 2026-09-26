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
- ~~`mrb_core.sv` からヒープを `mrb_heap.sv` に分ける~~ → **やめて P1 の最初に「1つの module のまま、関心ごとに
  include file に分ける」に変えた。** 理由: GC はレジスタファイル・定数・コールスタック・ヒープを全部触り、呼び出しと
  戻りも env を触るので、module を分けると全部を port で渡し、要求と応答の cycle が増えてトレースの一致を崩す危険だけが増える

### P1 オブジェクトモデル

#### 設計 (P1 以降の土台)

**回路に全部の組み込みメソッドを書かない。** mruby の mrblib と同じく、`Array#each` `String#split` `Hash#each` のような
メソッドは Ruby で書いた**プレリュード** (`fpga/prelude/*.rb`) に置き、プログラムと一緒に変換してコア自身で走らせる。
RTL が持つのは、値の型の判定、ヒープのオブジェクトの確保と読み書き (語・バイト)、整数の演算、**メソッド探索**、呼び出しと戻り、
GC だけにする。こうしないと P2〜P5 のたびに FSM が膨らむ。今の `SEND` の組み込み (番号で呼ぶ 24 個) は基本操作
(primitive) として残し、メソッド表から呼ぶ。

- **タグを 4bit にする。** nil / false / true / Integer / Symbol / Class (クラス番号の即値) / Object (ヒープの参照、
  種類は見出しのクラス番号) / 転送 / 見出し。Array と Proc は Object の一種になる (見出しのクラス番号で分かる)。
  空きは Float などのため
- **クラス番号。** 組み込み (Object、NilClass、TrueClass、FalseClass、Integer、Symbol、Array、Proc、Class、String、Hash、
  Range、Exception ...) は固定の番号、ユーザーのクラスとモジュールは 32 から。クラスメソッドは「メタクラス」
  (番号 | 0x8000) のメソッドとして扱う。ヒープの中だけの塊 (配列の中身、env) は特別な番号
- **メソッド表は変換器が静的に作り、ROM に置く。** クラスの本体 (`class Foo ... end`) の `def` / `attr_*` / `include` は
  変換器が読み、継承とモジュールを平らにして、クラスごとに「そのクラスで呼べる全メソッド」を
  (クラス番号 16bit, シンボル 16bit) → 飛び先 16bit の表 (1語 48bit にちょうど収まる) にする。開番地法のハッシュ表で、
  コアは 1〜数 cycle で引く。飛び先は「pc」「primitive の番号」「インスタンス変数の読み / 書き (attr_*)」の4種。
  表に無ければ NoMethodError (P4 までエラー停止)。`super` は「(持ち主のクラス, 名前) の次」を表す合成シンボルを
  変換器が作り、同じ表で引く。`define_method` などの動的な定義は変換時に止める
- **インスタンス変数** も同じ表で (クラス, @名前) → 番号を引く (モジュールのメソッドがどのクラスでも動くように)。
  オブジェクトの大きさはクラスごとに変換器が数える
- **定数。** `Foo::BAR` は変換器が静的に解決できる所は番号にし、できない所は (クラス, 名前) を表で引く。
  クラスの本体の中の定数の代入は、その本体を実行時に走らせる (`EXEC` は本体を self = クラスで呼ぶ呼び出し。
  `def` / `attr_*` / `include` は実行時は何もしない)
- **`new`。** primitive: オブジェクトを確保して R[a] に置き、同じ引数で `initialize` を呼ぶ。そのフレームには
  「戻り値で R0 (= オブジェクト) を上書きしない」印を付ける。`initialize` が無ければ Object#initialize (何もしない)
- **メソッドの先頭は必ず `ENTER`。** mruby が出さない時は変換器が足す。`ENTER` が引数の数を調べ、省略可能な引数の
  飛び先を選び、nregs までのレジスタを nil で埋める (今は呼ぶ側の S_CLEAR がしている。表から呼ぶと呼ぶ側は nregs を知らない)
- **ROM の先頭の語** に表の位置と大きさを書く (コアはリセット後に読む)
- **一番外の self** は Object のインスタンス (変換器が先頭で作る)。一般のグローバル変数は番号にして別の配列に置く
- **RTL の file 分け** は上の P0 のとおり include file で

#### P1c の設計 (オブジェクト)

- **オブジェクト** = `[見出し (クラス, インスタンス変数の数 n)] [インスタンス変数 × n]`。n は変換器がクラスごとに数える
  (親クラスの分が先、そのクラスのメソッドと `attr_*` に出る分、`include` したモジュールの分)。一番外の self (main) は
  Object のインスタンスで、変換器が先頭で作る (Object のインスタンス変数は一番外の `@x`)
- **`new`** は Class の primitive: (クラス, 0xFFFE) を表で引いて n を得て (無ければ 0)、確保し、R[a] に置いて `initialize` を送る。
  そのフレームには「戻り値で R0 を上書きしない」印 (ctor) を付ける。Object#initialize はプレリュード (引数 0 個)
- **インスタンス変数** は (self のクラス, `@x` のシンボル) を表で引く (親クラスへもたどる)。飛び先の種類 2 = 番号。
  `GETIV` は見つからなければ nil、`SETIV` はエラー。`attr_reader :x` は (クラス, :x) → 種類 2、`attr_writer` は
  (クラス, :x=) → 種類 3 (R[a+1] を書いて返す)。呼び出しで種類 2 / 3 に当たったら、その場で読む / 書く
- **`super`** は、今のメソッドが見つかったクラス (フレームごとに持つ mcls) の親から、同じ名前 (変換器が b に入れる) を引く。
  ブロックの中の `super` は変換時に止める
- **`include M`** はクラスごとに iclass (新しい番号) を作り、M のメソッドを写し、親の輪を C → iclass → 元の親 にする。
  M のインスタンス変数は C の番号の並びの後ろに足す
- **`is_a?` / `kind_of?` / `Module#===`** は、変換器が (0x4000 | クラス, 祖先の番号) → 1 を祖先の分だけ表に入れ、
  primitive が親をたどらずに1回引く。`respond_to?` は (クラス, シンボル) を親までたどって、あるかだけを見る
- **クラス変数 (`@@x`)** は、それを最初に代入するクラス (祖先の中で一番上) ごとの定数と同じ番号にする

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
| 2026-09-26 | P1a タグ・シンボル | 47 | 15 | 15 | |
| 2026-09-26 | P1b メソッド表・プレリュード | 48 | 16 (example は 0 / 32) | 16 | classes.rb を追加。止まる理由の上位は文字列 30、`.new` 25、`Foo::Bar` 18、`puts` 15 |
| 2026-09-26 | P1c オブジェクト | 49 | 17 (example は 0 / 32) | 17 | objects.rb を追加。止まる理由の上位は文字列 30、`GETMCNST` 18、`puts` 15 (`.new` は消えた) |

## 見つけたこと

- P0: 多重代入 (`a, b = make_counter(5)`) に `AREF` が要った (P3 の予定を前倒しで入れた)
- P0: `mrb_core_tb` の期待値を2回間違えた (BLKCALL のフレームが上のレジスタを nil で埋めること、R1 が最後に Proc になること)。
  どちらも参照インタプリタで同じ ROM を走らせて、RTL ではなくテストの誤りと確かめてから直した。
  テストベンチのケースは、先に参照インタプリタで期待値を出してから書く
- P1b: プレリュードの `self[i]` は `GETIDX` ではなく `SSEND :[]`、`self * 2` は `SSEND :*` になる。
  mruby の演算の命令は型が合わなければ同名のメソッドを送る (vm.c の `OP_MATHI` などで確かめた) ので、その落ち先と、
  Integer の演算の primitive を入れた。`!=` と `include?` は primitive をやめてプレリュードにした (回路の S_INCL が消えた)
- P1b: ブロックのフレームの R0 が「呼んだ側の self」になっていた (mruby は Proc を作った時の self)。プレリュードの `times`
  から呼ぶと self が Integer になるので、Proc に self を持たせた
- P1b: `Array#[]=` の参照の値を、伸ばす時の GC の前に読んでいた (GC で動いた後の古いアドレスを返す)。RTL は後で読んでいたので
  ファズより先に読み比べで見つけた
- P1b: Icarus が `always_comb` の中で2回書いてから読む変数と、`if` の条件の関数の呼び出しで時刻を進めなくなった
  (Verilator は通る)。spec §10 の「Icarus の癖」に足した
- P1b: 自分で書いた mrb_core_tb のケース1つの期待値が混乱していた。参照の実行結果を見て書き直した
- P1c: mrb_core_tb の新しいケースを、参照インタプリタで期待値を出さずに書いて、tb のレジスタが 16 本なのを忘れた
  (a + 引数 + 1 = 16 が範囲外でエラー)。上の決まりを守らなかった。RTL の誤りではなかった
- P1c: `fpga:gap` の事前検査 (`gap.rb`) が変換器と別に「定義されたメソッド」を数えていて、`attr_*` の名前と
  クラスの本体の宣言を知らず、objects.rb を止まると数えた。変換器の noops と同じ名前の一覧を持たせた
- P1c: 一番外の irep の先頭に main を作る2語を足したので、pc が 2 ずれる。`rom_test` の番号を直し、
  クラスの本体の `attr_*` / `include` (`SSEND` → `LOADNIL`) とクラス変数 (`GETCV` → `GETCONST`) を置き換えの一覧に足した
