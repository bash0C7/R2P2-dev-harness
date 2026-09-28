#!/usr/bin/env bash
# Undo apply.sh: restore both working copies and drop the rig-flavored
# libmruby build so a later board build cannot link rig code by accident.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$RIG_DIR/../.." && pwd)"
ESP32_REPO="${R2P2_ESP32_REPO:-$(cd "$HARNESS_ROOT/.." && pwd)/R2P2-ESP32}"
SUBMODULE="$ESP32_REPO/components/picoruby-esp32/picoruby"
MARKER="$ESP32_REPO/.qemu-ble-evq-applied"

if [ ! -f "$MARKER" ]; then
  echo "[qemu-ble-evq] not applied; nothing to revert"
  exit 0
fi

git -C "$SUBMODULE" apply -R "$RIG_DIR/radio_stub.patch"
git -C "$ESP32_REPO" apply -R "$RIG_DIR/r2p2-esp32.patch"

rm -f "$ESP32_REPO/components/picoruby-esp32/rig_injector.c"
rm -f "$ESP32_REPO/sdkconfigs/qemu_ble_evq"
rm -f "$ESP32_REPO/storage/home/app.rb"

rm -rf "$SUBMODULE/build/esp32-picoruby" "$SUBMODULE/build/esp32-femtoruby"

rm -f "$MARKER"
echo "[qemu-ble-evq] reverted in $ESP32_REPO"
