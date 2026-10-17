#!/usr/bin/env bash
# Undo apply.sh: restore both working copies and drop the rig-flavored
# libmruby build so a later board build cannot link rig code by accident.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$RIG_DIR/../.." && pwd)"
ESP32_REPO="${R2P2_ESP32_REPO:-$HARNESS_ROOT/vendor/R2P2-ESP32}"
SUBMODULE="$ESP32_REPO/components/picoruby-esp32/picoruby"
MARKER="$ESP32_REPO/.qemu-ble-evq-applied"
CATCHUP_MARKER="$ESP32_REPO/.qemu-ble-evq-catchup"

if [ ! -f "$MARKER" ]; then
  echo "[qemu-ble-evq] not applied; nothing to revert"
  exit 0
fi

if [ -s "$MARKER" ]; then
  # Reverse line order without `tail -r`: that flag is BSD-only, and under
  # pipefail its failure inside the Linux container aborted the revert halfway.
  sed '1!G;h;$!d' "$MARKER" | while read -r p; do
    if [ -n "$p" ]; then
      git -C "$SUBMODULE" apply -R "$RIG_DIR/$p"
    fi
  done
fi
git -C "$SUBMODULE" apply -R --ignore-whitespace "$RIG_DIR/radio_stub.patch"
git -C "$ESP32_REPO" apply -R "$RIG_DIR/r2p2-esp32.patch"
# Only what apply.sh applied: a branch that carries the catch-up keeps it.
if [ -f "$CATCHUP_MARKER" ]; then
  git -C "$ESP32_REPO" apply -R "$RIG_DIR/r2p2-esp32-catchup.patch"
  rm -f "$CATCHUP_MARKER"
fi

rm -f "$ESP32_REPO/components/picoruby-esp32/rig_injector.c"
rm -f "$ESP32_REPO/sdkconfigs/qemu_ble_evq"
rm -f "$ESP32_REPO/storage/home/app.rb"

rm -rf "$SUBMODULE/build/esp32-picoruby" "$SUBMODULE/build/esp32-femtoruby"

rm -f "$MARKER"
echo "[qemu-ble-evq] reverted in $ESP32_REPO"
