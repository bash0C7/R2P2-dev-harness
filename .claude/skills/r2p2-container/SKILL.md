---
name: r2p2-container
description: >-
  R2P2-dev-harness で、ESP-IDF・arm-none-eabi・gem を Mac に入れずに Apple Container の中で
  build・QEMU・upstream picoruby のテストを回す手順。picoruby の PR や branch を ESP32 の QEMU
  (evq rig、qemu_check) で試すとき、R2P2-ESP32 の firmware を build するとき、Pico 2 W の .uf2 を
  作るとき、upstream の rake test:gems:* や steep を回すとき、「container で」「Mac を汚さずに」
  「QEMU で確かめて」と言われたときに使う。
---

# r2p2-container: Mac を汚さずに build と QEMU を回す

ESP-IDF も arm-none-eabi も gem も Mac に入れない。build・QEMU・upstream のテストは、harness が持つ
常駐コンテナ `r2p2-dev-harness` (base image `espressif/idf:v5.5.4`) の中で回す。
仕組みと理由は README の「Apple Container で回す」と docs/spec.md §9。ここは回し方だけ。

- ホストで `brew` / `mise` / `gem install` を提案しない。足りないパッケージは `container/provision.sh` に足して `rake container:provision`
- 実機を触るタスク (`esp32:flash` / `upload` / `run` / `reboot`、`rp2040:*`) はホストのまま。container から serial は見えない
- コマンドは harness root で打つ

## 1. 状態を見る (毎回最初に)

```sh
container system status                              # 止まっていれば container system start
container image list | grep espressif/idf            # 無ければ rake container:image (初回だけ。入れると約 14 GB)
ls vendor/R2P2-ESP32                                 # 無ければ rake esp32:setup
```

`rake container:image` は disk の空きが 20 GB (`CONTAINER_MIN_FREE_GB`) 未満なら止まる。
何を消して空けるかは人が決める。`container system df` の reclaimable は当てにならない (§9)。

## 2. PR の picoruby を試す

picoruby の tree (clone でも worktree でも) は harness の外にあるものを使う。作る・最新にする (`git pull`)・消すのは
その tree の側の仕事で、harness の task は無い。submodule は init 済みであること (`container:up` が確かめて止まる)。

```sh
export ESP32_PICORUBY=<picoruby の tree の絶対パス>
EVQ_VM=mruby  rake "container:rake[esp32:evq_green]" > <scratchpad>/evq-mruby.log  2>&1
EVQ_VM=mrubyc rake "container:rake[esp32:evq_green]" > <scratchpad>/evq-mrubyc.log 2>&1
```

- 1 本数分かかる。Bash の background で回す。log の redirect はホスト側なので scratchpad に書いてよい (CLAUDE.md)
- 判定は log 末尾の `[esp32:evq_green] PASS: ...` / `FAIL: ...`。`evq_red` / `evq_oom_red` は RED が期待どおり
- 他の evq: `evq_oom_green` / `evq_oom_red` / `evq_flood_green` / `evq_flood_paced_green` / `evq_flood_hb_green` (`rake -T esp32:evq`)

| やりたいこと | コマンド |
|---|---|
| upstream のテスト | `CMD='rake test:gems:picoruby' DIR=$ESP32_PICORUBY rake container:exec` (`test:gems:femtoruby` も) |
| steep | `rake "container:ruby[4.0.1]"` を一度、以後 `CONTAINER_RUBY=4.0.1 CMD='BUNDLE_FROZEN=true bundle install && rake test:gems:steep' DIR=$ESP32_PICORUBY rake container:exec` |
| Pico 2 W の .uf2 | `CMD='rake r2p2:picoruby:pico2_w:prod' DIR=$ESP32_PICORUBY rake container:exec` |
| DualKey の firmware | `rake "container:rake[esp32:build]"`、焼く前に `rake "container:rake[esp32:qemu_check]"` |
| 任意のコマンド | `CMD='...' DIR=<harness 相対か絶対> rake container:exec`、対話は `rake container:shell` |

## 3. 罠

- **`ESP32_PICORUBY` / `CONTAINER_CPUS` / `CONTAINER_MEMORY` を今と違う値で明示すると、コンテナを作り直す** (provision に数分)。
  付けずに呼べば今のコンテナをそのまま使う。別の branch に替えるときだけ付け替える
- **container から見えるのは harness root、ghq の picoruby clone、R2P2-ESP32 だけ。** scratchpad の script は見えない。harness の `tmp/` に置く
- **ホストの環境変数は許可リストだけが渡る** (`tools/container/run_args.rb` の `PASS_ENV_NAMES` / `PASS_ENV_PREFIXES`)。
  新しい変数を渡すなら、そこと `run_args_test.rb` に足す
- **重ねた tree の中で `git status` しない。** 入れ子の submodule の gitdir が相対パスなので、container の中のその位置からは
  `not a git repository` になる。tree の状態は tree 自身のパス (`DIR=$ESP32_PICORUBY`) かホストで見る
- **evq rig を途中で殺したら、container の中で外す:** `CMD='bash firmware-patches/qemu-ble-evq/revert.sh' rake container:exec`。
  submodule の位置に重ねた tree は container の中にしか無いので、ホストからは外せない
- **`esp32:build` は `vendor/R2P2-ESP32/sdkconfig.defaults` に DualKey の console 設定を書き足し、target が esp32s3 でなければ `set-target` する。**
  設計どおりで、戻さない。QEMU 系 (`qemu_check`、evq rig) は `sdkconfigs/qemu` が console を UART に戻すので、書き足した後も通る

## 4. 片付けと報告

```sh
rake container:stop                                  # 使い終わったら memory を返す。次の container:* が起こす
rake container:down                                  # コンテナごと消す (image と tmp/container は残る)
```

報告の前に、ホストで picoruby の tree と `vendor/R2P2-ESP32` が clean に戻っていることを `git status` で見る。
QEMU が green でも実機の完了ではない (CLAUDE.md の「完了の線引きは実機」)。QEMU で何を確かめたかを書く。
