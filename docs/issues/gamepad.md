# 課題: USB HID ゲームパッド

やりたかったこと: PicoRuby を Xbox コントローラー偽装のゲームパッドにする。
example 第1号として、Raspberry Pi Pico 2 W の基板上のボタン1つを使う。

**v1 ではやらない。** USB descriptor を変えないと決めたため。
ここは課題の記録であって、計画ではない。

## 何が邪魔しているのか

`vendor` 側の `mrbgems/picoruby-r2p2/ports/rp2040/usb_descriptors.c` で
インタフェース構成が C にハードコードされている。

- インタフェースは CDC×3 + HID×3 (keyboard / mouse / consumer)。
  `ITF_NUM_TOTAL` は enum の最後の要素で、コンパイル時に決まる
- `tusb_config.h`: `CFG_TUD_CDC 3` / `CFG_TUD_HID 3` / `CFG_TUD_MIDI 0` / `CFG_TUD_VENDOR 0`
- 3つの HID はいずれも **report ID を持たない** (`TUD_HID_REPORT_DESC_KEYBOARD()` 等を
  そのまま使っている)。report ID が無いので、
  **ゲームパッドを既存インタフェースに相乗りさせられない**

つまり4本目の HID インタフェースを足すには picoruby 本体の C を変えるしかなく、
「既存 repo に直接変更を加えない」という制約と正面から衝突する。

## 取りうる道

| 道 | 中身 | 代償 |
|---|---|---|
| A. overlay / patch | 取得した `vendor/picoruby` の working copy にだけ patch を当てる | upstream 追従のたびに patch の当たり外れが出る |
| B. fork branch | `bash0C7/picoruby` に branch を持ち `PICORUBY_REF` で差す。R2P2-darwin と同じ運用 | branch のメンテが増える |
| C. upstream へ PR | report ID 付き HID + ゲームパッドを提案する | 完了が他人の時間に依存する |

C が本筋。A は「本 repo の中で閉じる」点で B より軽いが、
descriptor は enum とエンドポイント番号が絡むので patch の粒度が大きく、壊れ方が静か。

## Xbox 偽装には2通りある

- **XInput (本物)**: ベンダクラス。`CFG_TUD_VENDOR` と専用の VID/PID が要る。現在 0
- **標準 HID ゲームパッド**: TinyUSB に `TUD_HID_REPORT_DESC_GAMEPAD` がある。
  macOS はそのまま認識する。難易度が段違いに低い

USB で行くなら後者から。

## BLE-HID なら C 変更が要らない、は半分しか正しい

`picoruby-ble-hid` の report map は Ruby 側の文字列定数
(`KEYBOARD_REPORT_MAP` / `CONSUMER_REPORT_MAP` / `MOUSE_REPORT_MAP`) で、
`_build_report_map` が enabled なものを連結する。
**report map を足すだけなら確かに C 変更は要らない。**

しかし report map だけでは動かない。`BLE::HID#initialize` が

- GATT database の characteristic (Report Reference descriptor 込み) を
  keyboard / consumer / mouse の3つ分**直書き**している
- `@keyboard_input_handle` / `@consumer_input_handle` / `@mouse_input_handle` を
  そこで拾い、`_flush_reports` がその3本だけを見ている

ので、4本目の report characteristic を subclass から足す隙が無い。
`initialize` は分割されておらず、super を呼ばずに全部書き直す以外の道が無い。

現実的な抜け道は2つ。どちらも v1 では採らない。

1. **既存の report slot を乗っ取る。** `_build_report_map` を override して
   keyboard の代わりに Report ID 1 のゲームパッド map を返し、
   `@keyboard_report` にゲームパッドの payload を入れて `keyboard_send` の経路で流す。
   C 変更ゼロで届くが、keyboard を名乗る口からゲームパッドを出す形になる
2. **upstream の `initialize` を分割してもらう。** report ごとの characteristic 追加を
   メソッドに切り出せば、subclass で足せるようになる。C ではなく Ruby の PR

## 判断の材料

- CDC-MIDI と BLE-HID のクイック送信は、既存 repo を一切触らずに到達できる
- USB HID ゲームパッドだけが C を要求する
- 本 repo の動機は「USB 周辺機器を作るライブラリを用意すること」なので、
  器が固まったあとに descriptor の道 (A / B / C) を選ぶ方が、選択の材料が揃う
