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

- 名指し: hello.rb (puts と式展開)、strings.rb (String のメソッド)、example の文字列を使うもの

#### P2 の設計

- **String は Array と同じ形** (`[見出し String] [長さ] [中身への参照]`、中身は `[見出し] [バイト × 容量]`、**1語に1バイト**
  (Integer の値として))。計画の「4 byte / 語」はやめた: 配列の確保・伸長・写し (S_AELEM の区間、push) をそのまま使え、
  RTL がほとんど増えない。ヒープは1バイト1語を食うので、足りなければ HEAP_SIZE を上げる
- **pool の文字列は ROM のデータ領域** (プログラムとメソッド表の間) に 1語 4バイトで置く (バイト j は bit 8j から)。
  `STRING a b c`: b = データの語アドレス、c = 長さ。コアは確保してから ROM を1語ずつ読んで写す (1バイト 2 cycle)
- **シンボルの名前も ROM に置く。** シンボル表 (シンボル番号 → {データの語アドレス, 長さ}) の先頭を `TABLE` の c に入れる。
  `Symbol#to_s` (primitive SYMSTR) が表を引いて `STRING` と同じに作る
- **`STRCAT a` は変換器が下げる:** `SEND a+1 :to_s` と `SEND a :<< 1`。式展開は必ず新しい `STRING` から始まるので
  (mrbc の出力で確かめた) R[a] を伸ばしてよい
- **String の primitive は最小限** (受け手が String でなければエラー): `bytesize`、`getbyte` (AGET と同じ意味)、
  `__aset` (setbyte の中身、値は 0..255)、`__push` (<< の中身、1バイト)、`__slice(i, n)` (範囲内の部分を新しい String に)。
  Array の `size` `length` `empty?` は String も受ける。ほかの String のメソッドはプレリュード (Ruby) で書く
  (`==` `+` `*` `<<` `size` (UTF-8 の文字数) `[]` `to_s` `inspect` `to_i` `upcase` `downcase` `split` `strip`
  `start_with?` `include?` `index` `reverse` `chars` `each_char` `bytes` `ord`、Integer の `to_s` `chr` `inspect`、
  nil / true / false / Symbol / Array の `to_s` `inspect`)。マルチバイトの文字は UTF-8 として数える (バイトで切って黙って違う結果にしない)
- **出力は console ポート** (`$CONSOLE`、出力ポート 3) に1バイトずつ書く。`puts` `print` `p` はプレリュードで、
  トレースは今の O 行のまま。参照との突き合わせは、CRuby の標準出力と console ポートに書いたバイト列を比べる
- **`LOADL`** は 32bit に収まる整数なら `LOADI32` にする。収まらない整数、Float、BIGINT は変換時に止める
### P3 Hash、Range、case、Array の残り、キーワード引数

- `Hash` (`HASH` `HASHADD` `HASHCAT`、`[]` `[]=` `each` `keys` `fetch` ...)、`Range` (`RANGE_INC` `RANGE_EXC`、`each`、`include?`)
- `case` / `when` (`===`)、`Array.new` `join` `each_slice` `sort` `select` `reject` `inject` など example に出るもの
- キーワード引数 (P1d の残り: `ENTER` の key / kdict、`KARG` `KEY_P` `KEYEND`、呼び出しの nk)
- 名指し: collections.rb (Hash / Range / case / Array)、kwargs.rb

#### P3 の設計

- **Hash・Range はプレリュードの Ruby のクラス** (組み込みの番号 12 / 13 のまま)。Hash は `@keys` `@vals` の2つの配列で、
  挿入順を保ち、キーは `==` (`eql?`) で線形に探す (小さい Hash しか出ない)。Range は `@first` `@last` `@excl`
- 回路の変更は、組み込みのクラスのうち Hash・Range・Exception (15) を `new` できてインスタンス変数を持てることだけ
  (`new_ok` / `iv_ok` / ref の `ivar_addr`)
- **命令は変換器が下げる:** `HASH a n` → `ARRAY a 2n` + `SEND a :__to_hash`、`HASHADD a n` → `ARRAY a+1 2n` + `SEND a :__add_pairs 1`、
  `HASHCAT a` → `SEND a :__merge! 1`、`RANGE_INC a` / `RANGE_EXC a` → `SEND a :__range_inc 1` / `:__range_exc 1`
- **Array の残りはプレリュード。** `Array#[]` は `(i)` だけ primitive で、`(i, n)` と `(range)` はプレリュード (`__aget` を呼ぶ)。
  `Enumerable` (each を使うもの) を Array・Hash・Range で共有する
- **`case` / `when`** は `===` を送るだけ (P2 で Object#=== と Module#=== がある)。Range#=== は include?
- **キーワード引数** (PicoRuby の vm.c の `vm_op_enter` / OP_SEND と同じ意味):
  - 呼ぶ側: nk 組のキーワードは Hash にしてから呼ぶ。変換器が下げる: `ARRAY k 2nk` + 作業用レジスタ S (組とブロックより上) で
    `__to_hash` + `MOVE k S` (+ ブロックを k+1 へ)、最後に印 (c の bit 8、KW) 付きの `SEND`。`**h` (nk = 15) は `h.empty?` なら印なしで呼ぶ
  - フレームは印を持つ (`argkw`)。ブロックの枠はその1つ後ろ。`new` は initialize へ、Proc#call はブロックへ印を渡す。ほかの primitive はエラー
  - `ENTER` (c の bit 11 = kd: キーワードか **opts を受ける): kd でなく印があれば、Hash を最後の引数として数える
    (引数 14 個以上なら止める)。kd なら R[len+1] = 渡された Hash (無ければ回路が空の Hash を作る: Hash の形 `@keys @vals @default
    @default_proc` を変換器が確かめる)、ブロックは R[len+2]
  - `KARG` / `KEY_P` / `KEYEND` は、作業用レジスタ N = nregs (フレームの上) で `R[len+1].__karg(:k)` / `key?(:k)` / `__keyend` を
    呼ぶ形に変換器が下げる (KARG は Hash から消す。**opts には残りが入る)
### P4 例外

- `raise` / `rescue` / `ensure` / `retry` (`EXCEPT` `RESCUE` `RAISEIF` `JMPUW`)。irep の catch handler を ROM の表にする
- コアの実行時エラー (0 で割る、NoMethodError、型の違い) を例外にし、`rescue` できるようにする。捕まえなければ今と同じく止まる
- 名指し: exceptions.rb

#### P4 の設計 (PicoRuby の vm.c の L_RAISE / catch_handler_find / OP_EXCEPT / OP_RESCUE / OP_RAISEIF と同じ意味)

段を3つに分ける:
- **P4a 例外と普通の流れ。** catch handler (種類 rescue / ensure、begin、end、target) を全部の irep から集め、pc (語) に直して
  ROM の表にする (1語 = {種類, begin, end, target}、irep ごとに後ろから = vm.c の探す順)。表の場所と数は `HTABLE` (FPGA だけの命令、
  handler がある時だけ pc 1 に置く)。例外はコアのレジスタ `exc` (GC の根)。`raise` はプレリュードで例外を作り、primitive `__raise` で
  投げる。投げるとコアは今のフレームの pc (呼び出し元のフレームは戻り先 - 1) を覆う handler を表から探し、無ければフレームを畳んで
  (env は写す) 呼び出し元で探す。見つかれば target へ。一番外まで無ければエラーで止まる。`EXCEPT a` は R[a] = exc (exc は nil に)、
  `RESCUE a b` は R[b] = R[a].is_a?(R[b]) (ISA の行)、`RAISEIF a` は R[a] が nil でなければ投げ直す。
  例外のクラスはプレリュード (Exception は組み込みの 15、ほかは Ruby のクラス)。`ensure` は普通の流れ (本体の後に落ちる) と
  例外の時に動く
- **P4b return / break / next / JMPUW で ensure を抜ける。** vm.c は RBreak (印の付いた疑似例外) で ensure を走らせてから続ける。
  最初は「P4a では変換時に止める」つもりだったが、`g { break }` のように ensure を持つメソッドのフレームをブロックの break が
  畳む所は静的に見つからない (黙って ensure を飛ばす)。止められないので P4a と一緒に作った: 例外と同じ状態機械で、
  畳むフレームごとに ensure を探し、あれば巻き戻しの塊 (種類、行き先、値) を exc に置いて ensure へ飛び、
  ensure の最後の RAISEIF が塊を受けて続ける (spec §10「例外 (P4)」)
- **P4c コアのエラーを例外にする** (NoMethodError、ArgumentError、ZeroDivisionError ...)。P4a では今と同じくエラーで止まる
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
| 2026-09-26 | P1d 引数 | 50 | 18 (example は 0 / 32) | 18 | args.rb を追加。止まる理由の上位は文字列 30、`GETMCNST` 18、`puts` 15。キーワード引数は P3 の後 |
| 2026-09-26 | P1e 定数の path・グローバル変数 | 51 | 19 (example は 0 / 32) | 19 | consts.rb を追加。`GETMCNST` は止める理由から消えた (`GPIO::OUT` などは P5 でクラスができれば通る)。上位は文字列 30、`puts` 15 |
| 2026-09-26 | P2 文字列と出力 | 53 | 23 (example は 2 / 32: picoruby-dfu の app_1 / app_2) | 23 | hello.rb、strings.rb を追加。止める理由の上位はデバイス (`start` 14、`connect` 8、`require psg` 8)、`HASH` 4、Float 3 |
| 2026-09-26 | P3a Hash・Range・Array | 54 | 25 (example は 3 / 32) | 25 | collections.rb を追加。使わないメソッドを ROM から落とす (live_ireps)。上位はデバイス |
| 2026-09-26 | P3b キーワード引数 | 55 | 26 (example は 3 / 32) | 26 | kwargs.rb を追加。止める理由はデバイス (P5)、Float 3、`getch` など |
| 2026-09-26 | P4a+b 例外・ensure の巻き戻し | 56 | 27 (example は 3 / 32) | 27 | exceptions.rb を追加。使わないクラスを表から落とす (live_classes)。止める理由はほぼデバイス (P5)。catch handler は止める理由から消えた |

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
- P1d: キーワード引数は Hash を要する (mruby は kdict を Hash にする) ので、P3 (Hash) の後に回す。変換時に止める
- P1d: ブロックの `ENTER` を `NOP` にして BLKCALL が引数を埋めていたので、`|a, b|` に配列1つを渡すと展開されていなかった
  (黙って違う動き)。ブロックも `ENTER` を残し、proc の展開と lambda の検査を `ENTER` に移した。Proc の info から引数の数と nregs を外した
- P1d: 確保の語数 `need` が HB+1 bit で、splat した大きな配列の残りの長さで折り返し得た。17 bit にし、GC の後も入らなければエラー
- P1d: Icarus が APOST の書き込みの値 (`always_comb` の `if` の中でヒープを2段たどる三項演算子) で時刻を進めなくなった。wire にした
- P1d: tb の期待値を参照インタプリタで出す道具 (`rake fpga:tb:ref`、tb の `+dumprom`) を作った。自分の書いたブロックの式の誤りを1つ見つけた
- P1e: 空の本体のクラス (`class E < StandardError; end`) は mruby が `EXEC` を出さず、変換器が「本体が無い」と止めていた。
  P4 の例外クラスで必ず要るので直した
- P1e: 定数の字句の入れ子を名前の path から作っていたので、`class A::B` の中で `A` の定数が見えてしまう (Ruby の cref では見えない)。
  irep ごとに cref を持たせた
- P2: 計画の「文字列は 4 byte / 語」をやめ、1語に1バイト (Array と同じ形) にした。配列の回路をそのまま使えるため。
  ヒープを食うので、足りなくなったら HEAP_SIZE を上げる
- P2: `while` の中の `break` は mruby が `JMPUW` (ensure を畳むジャンプ) を出す。プレリュードで初めて出た。
  catch handler の無い irep ではただの `JMP` にした (P4 で ensure を畳む)
- P2: `String#count` を部分文字列の数と思い込んで書いた。CRuby は文字の集合に入る文字の数。CRuby との突き合わせで見つけた。
  `Integer#to_i` が無かった (format の中で使った)
- P2: `fpga:gap` の事前検査が、プレリュードでわざと未定義にして止めるメソッド (`__*_not_supported`) を「止める理由」に数え、
  全部を止まると数えた。`__` で始まる名前は数えない
- P2: Icarus がまた時刻を進めなくなった (`always_comb` の中の `val_of(ra1) < ...`)。比べる式を wire にした
- P2: fuzz の heap_program のメソッド表 (32 語) が項目で満杯になり、with_table が黙って項目を捨てていた (呼ぶとエラーで終わる
  program が増えて気づいた)。heap_program の表を 64 語にした
- P2: プレリュードが ROM を 4000 語ほど使う (使わないメソッドも全部入る)。example が入り切らなくなったら、
  呼ばれないメソッドを落とす (名前のシンボルがどこにも出てこない def を消す)
- P2: PERIDOT-Air の top には console のピンがまだ無いので、ボードエミュレーターは console を見ない (UART の TX は P5)
- P3: プレリュードが大きくなり、collections.rb の ROM が 9647 語 (> 8192) になった。呼ばれないメソッドを落とす (live_ireps) を入れた
  (名前で数えるので、プレリュードが使う名前のメソッドは残る。hello.rb で 4800 語)
- P3: コーパスの .dump を作る正規表現が、iseq のバイト位置を 3 桁と決めていた。1000 バイトを超える irep の行を黙って落とし、
  rom_test の突き合わせの数がずれて気づいた
- P3: PicoRuby の `Hash#inspect` は `{"a" => 1, b: 2}` (Ruby 3.4 の形)、CRuby 3.3 は `{"a"=>1, :b=>2}`。PicoRuby に合わせ、
  CRuby には同じ形の Hash#inspect を入れてから比べる。PicoRuby の組み込みには `Hash#min_by` `sort_by`、`Array#tally` `zip`
  `each_slice`、`Range#sum` などが無い (プレリュードは持つ)。collections.rb は picoruby とは比べない
- P3: `Range#===` を `<` で書いて、`(1..9) === "hi"` が String#< で止まった。CRuby の cover? と同じく <=> で比べ、比べられなければ偽
- P3: キーワード引数は PicoRuby の vendor の vm.c (`vm_op_enter`、OP_SEND) を読んで合わせた。mruby 3.3 の説明と違い、
  KARG で Hash から消し (dup しない)、kd のメソッドに Hash が渡されなければ空の Hash を作る。呼ぶ側の Hash 作りと KARG は
  変換器がプレリュードの呼び出しに下げ、回路は印の受け渡しと空の Hash を作るだけにした
- P3: tb のキーワード引数のケースで、比べるために取っておいたレジスタが呼び出し先のフレームの中にあり、ENTER が nil にした
  (参照インタプリタと RTL は一致していて、テストの誤り)
- P4: 例外のクラスをプレリュードに 15 足したら、`===` がどのプログラムにもあるので is_a? の行が全クラス分増え、メソッド表が
  1024 語から 2048 語に倍になり、全プログラムが 1200 語ほど増えた (collections.rb は 8134 語で ROM の端)。生きているクラスだけ
  表に行を置く (live_classes) にして、+150 語ほど (クラスの定義のコードと `$!`) に戻した
- P4: ensure を通り抜ける break は、ensure を持つメソッド (yield する側) のフレームをブロックが畳む時にも起きる。
  ブロックを作った所しか静的には見えないので、「P4b は変換時に止める」はできなかった (黙って ensure を飛ばす)。P4a と一緒に作った
- P4: `retry` は mruby では rescue 節を覆う ensure (`$!` を戻すためのもの) を通る JMPUW で、巻き戻しの塊を作る。
  retry を止めていたら、よくある書き方が通らなかった
- P4: PicoRuby の `Exception#inspect` はメッセージが無ければクラスの名前だけ (`TypeError`)、CRuby 3.3 は `#<TypeError: TypeError>`。
  PicoRuby に合わせ、CRuby には同じ形の inspect を入れてから比べる。`Exception.new(nil).message` は PicoRuby だけ `""` (CRuby に合わせた)
- P4: ブロックの中の return が new の initialize のフレームを畳む時、RTL は戻り値で R0 を上書きし、参照は上書きしなかった
  (コードを読んで見つけた。どのテストも通っていない組み合わせ)。巻き戻しを1つの状態機械にまとめた時に、RTL も上書きしないようにそろえた
- P4: rom.rb に Enumerator の連鎖 (`each_with_index.any?`) と正規表現のキャプチャを書き、変換器が PicoRuby で走らなくなる所だった。
  CRuby の突き合わせでは見つからないので、書いたら `rake fpga:corpus` (PicoRuby で変換) を回す
- P4: fpga:fuzz と fpga:gap を同時に回すと、同じ build/fpga/verilator/mrb_run_tb で Verilator のビルドがぶつかって落ちる
