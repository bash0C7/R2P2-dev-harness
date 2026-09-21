# FAQ

転送 (upload / run) のあとによく出る問題。罠ではなく、普通に起きる事象。

## 板に `/home/app.mrb` (または `app.rb`) が残っていて、転送が失敗する

起動時に `/etc/init.d/r2p2` が `$HOME/app.mrb` → `$HOME/app.rb` を自動実行する。
戻ってこない app (無限ループの bench、常駐アプリ) を置いたままだと shell が上がらず、
次の転送が次のように失敗する:

```
[pmput] FAILED: [picomodem] /home/app.mrb started but never returned, so main_task.rb never reaches `$shell.start` ...
```

- **Pico 2 W**: `rake rp2040:upload` / `run` は `$>` が返らなければ Ctrl-C で app を止めてから転送する。通常は何もしなくてよい
- **DualKey (ESP32)**: Ctrl-C で止められない段階で失敗する。storage partition だけを消す
  (firmware は残る。`/home` の中身は消える):

  ```sh
  . ~/esp/esp-idf/export.sh
  python -m esptool --chip esp32s3 -p <DualKey の port> erase_region 0x210000 0x100000
  ```

  port は `tools/esp32/` の script と同じく `ioreg` の製品名 `USB JTAG/serial debug unit` で引く
  (`/dev/cu.usbmodem*` の glob は使わない)。消したあと `rake esp32:run` をやり直す。
  他の session が板を使っていないことを先に確かめる (board の lock は `esptool` を守らない)
