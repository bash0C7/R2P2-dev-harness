#!/usr/bin/env bash
# 常駐コンテナに一度だけ入れる追加パッケージ (root で走る。rakelib/container.rake の container:up)。
# base は R2P2-ESP32 の CI と QEMU job が使う espressif/idf:v5.5.4 (Ubuntu 24.04、QEMU と ruby 同梱)。
#   ruby-dev libssl-dev ... picoruby の host build と bundle install (base は ruby だけ持つ)
#   rake ruby-bundler ..... `rake` / `bundle` の名前で呼べるようにする
#   procps ................ rig と boot check の pkill
#   libyaml-dev zlib1g-dev  container:ruby が Ruby をソースから build するのに要る (psych / zlib)
#   gcc-arm-none-eabi 一式  Pico 2 W 向け r2p2 build (pico-sdk が picotool を build する libusb は base にある)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ruby-dev libssl-dev rake ruby-bundler procps pkg-config libyaml-dev zlib1g-dev \
  gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib
rm -rf /var/lib/apt/lists/*
