---
name: r2p2-fpga
description: >-
  R2P2-dev-harnessで、FPGA (PERIDOT-Air) のrite_coreをQuartusで合成して焼く手順。PERIDOT-Airに合成して焼くとき、
  設定用フラッシュ (EPCQ16互換のW25Q16) に書いてPCなしで起動させるとき、JTAGがつながらない・
  CONF_DONEが立たない・LEDが全部点くとき、展示の画面 (fpga/exhibit) を出すとき、
  「FPGAを焼いて」「PERIDOT-Air」「設定用フラッシュ」「EPCQ」「JTAG」と言われたときに使う。
---

# r2p2-fpga: PERIDOT-Airに合成して焼く

`rite_core` (mrubyのバイトコードを直接実行する回路) をQuartusで合成し、PERIDOT-AirのSRAMか設定用フラッシュに書く。
仕組みと事実の記録はdocs/spec.md §10の「PERIDOT-Air」。ここは回し方だけ。

- 実機で動いたとは、焼いてLEDを目視するまで書かない。`rake`のexit 0や照合の一致は中間の証拠で、動作の証拠ではない
- QuartusはApple containerの中で走る。`PATH="$PWD/tools/fpga/container:$PATH"`を付けてrakeを呼ぶ
- コマンドはharness rootで打つ

## 1. 状態を見る (毎回最初に)

```sh
container system status                  # 止まっていればcontainer system start
container image list | grep r2p2-quartus # 無ければcontainer build --arch amd64 -t r2p2-quartus tools/fpga/container
container volume list | grep quartus     # 無ければtools/fpga/container/install.sh <installerを置いたdir> (installerは人が落とす)
which openFPGALoader                     # 無ければbrew install openfpgaloader
openFPGALoader --scan-usb                # USB-Blasterが見える
rake fpga:detect                         # JTAGのIDCODEと設定用フラッシュのJEDEC ID
```

`rake fpga:detect`は、IDCODEが`0x020f10dd`、JEDEC IDが`0xef4015` (W25Q16、2 MiB) なら配線と板が通っている。

## 2. 流れ

```sh
rake fpga:rite:hex                       # ROMを作り直す
rake fpga:rite:check                     # 回路 (Verilator) とhostのpicorubyでピンの変化の列を比べる
PATH="$PWD/tools/fpga/container:$PATH" rake fpga:rite:build   # Quartusで合成。.svfと.rbfができる
rake fpga:flash                          # .svfをSRAMに書く (電源を切ると消える)。LEDを目視
rake fpga:flash:backup                   # 設定用フラッシュを書く前に2回吸い出して残す (tmp/epcq-backup/)
rake fpga:flash:epcq                     # .rbfを設定用フラッシュに書き、吸い出して全バイトを照合する
```

1. SRAMでLEDを目視して合格してから`fpga:flash:epcq`に進む
2. `fpga:flash:epcq`が`verified:`を出したら、micro-Bを抜き差しする。PCにつながず外部USB電源だけでも、USER_LED0が約0.5秒ごとに点滅すれば合格 (R3、`fpga/rite/blink.rb`)
3. 出荷時の設定用フラッシュは全2 MiBが`0xff` (空)。初めて書く前に`fpga:flash:backup`を必ず取る

## 3. JTAGの配線 (7本)

micro-Bは給電だけ。JTAGはUSB-Blasterの10Pと板のJ2 (6P) をジャンパー線7本で直結する。

```
J2 (▷ が1番、左上)
  1 TDO   2 3.3V
  3 TCK   4 TDI
  5 TMS   6 GND
```

| USB-Blaster 10P | 板 |
|---|---|
| 1 TCK | J2-3 |
| 3 TDO | J2-1 |
| 5 TMS | J2-5 |
| 9 TDI | J2-4 |
| 4 VCC | 電源ピンソケットの3.3V |
| 2 GND | 電源ピンソケットのGND |
| 10 GND | J2-6 (GND) |

6本だと`--detect`は通っても、約294万bitを送る`.svf`の書き込みでCONF_DONEが立たないことがある。7本目の10 GND → J2-6を必ずつなぐ。
同梱のJTAG-CONNと10Pリボンを通すとIDCODEが全部0になった (原因は未切り分け)。ジャンパー線の直結を使う。

## 4. 症状と対処

| 症状 | 対処 |
|---|---|
| `TDO is stuck at 0` / IDCODEが全部0 | JTAG-CONNと10Pリボンを外し、上の表の7本の直結にする。TDO (blaster 3 → J2-1) とGNDの2本 (2 → 電源ピンソケット、10 → J2-6) を確かめる |
| IDCODEがでたらめ (`0x01000100`など) | ジャンパー線を両端とも奥まで挿し直す |
| `--detect`は通るが`fpga:flash`でCONF_DONEが立たない | 7本目のGND (10 → J2-6) を足す |
| JEDEC IDが`00`で「Read ID failed」 | `-f`の経路でbridgeを載せた直後に読んだ状態。`rake fpga:flash:epcq`は検出の経路でbridgeを載せて残してから書くので、手で`openFPGALoader -f`を打たずにこのタスクを使う |
| JEDEC IDが`ff` | bridgeが載っていない状態。6本の配線でbridgeの構成に失敗したときと、`--skip-reset`無しの検出が終わってFPGAがリセットされた後の`--skip-load-bridge`で出た。7本の配線にして`rake fpga:detect`でJEDEC IDを確かめる。出荷時の設定用フラッシュの中身 (全部`0xff`) とは別の話 |
| `fpga:flash:epcq`の照合で食い違う | `openFPGALoader --verify`は照合の途中でbridgeが消えて食い違いを出したので使わない。タスクは書いた後にbridgeを載せ直して吸い出し、食い違ったオフセットを出す。もう一度`fpga:flash:epcq`を回す |
| LEDが全部点く | 電源投入直後とbridgeを載せた状態は、回路がLEDを駆動していないので全部点く。動作の印ではない。SRAMへは`.svf` (`rake fpga:flash`) で書く |
| 設定用フラッシュに書いたのに起動しない | micro-Bを抜き差ししたかを確かめる。書き込み直後はbridgeが載ったままで、LEDは全部点く |

## 5. 展示の画面

`fpga/exhibit/index.html`をChromeで開く。`f`で全画面。1画面にすべてを並べ、「次の命令」ボタンで1命令ずつ実行位置と説明を進める。
画面には光る要素や点滅を置かない (実機のLEDを目立たせるため)。文言は肯定形だけで書き、日本語は`agy`で磨く。

```sh
open -a "Google Chrome" fpga/exhibit/index.html
```

## 6. 人に頼むこと

| 頼むこと | 代行できない理由 |
|---|---|
| ジャンパー線の配線と挿し直し | 物理操作で、配線の良否はrakeの`--detect`で判定できるが挿すのは人 |
| micro-B / 外部USB電源の抜き差し | 設定用フラッシュからの起動は電源の入れ直しでしか起きない |
| USER_LEDの目視 | LEDの点滅は板の外に出る信号で、hostから観測する手段が無い |

頼むときは1回の操作で判定できるよう、先に`fpga:flash:epcq`の`verified:`まで進めておく。同じ操作を繰り返し頼まない。

## 7. 片付けと報告

報告の前に、`git status`で`tmp/epcq-backup/`と`build/`がcommit対象に入っていないことを見る。
照合の一致とLEDの目視は別の事実として書く。LEDを目視していなければ「焼いた、照合は一致、目視は未」と書く。
