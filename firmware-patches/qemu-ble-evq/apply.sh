#!/usr/bin/env bash
# Apply the qemu-ble-evq overlay to the R2P2-ESP32 working copy and the
# picoruby submodule inside it. Working-copy only — never commit these.
# revert.sh undoes everything; a marker file makes both idempotent.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$RIG_DIR/../.." && pwd)"
ESP32_REPO="${R2P2_ESP32_REPO:-$(cd "$HARNESS_ROOT/.." && pwd)/R2P2-ESP32}"
SUBMODULE="$ESP32_REPO/components/picoruby-esp32/picoruby"
MARKER="$ESP32_REPO/.qemu-ble-evq-applied"

[ -d "$SUBMODULE" ] || { echo "picoruby submodule not found at $SUBMODULE" >&2; exit 1; }

if [ -f "$MARKER" ]; then
  echo "[qemu-ble-evq] already applied ($MARKER)"
  exit 0
fi

# Optional fault-injection layers on top of the radio stub (mruby glue
# only). EVQ_OOM=1: BLE_write_data raises NoMemoryError once, expecting
# the glue to contain it. EVQ_OOM_RED=1: additionally strip that
# containment, so the same run must go red. revert.sh reads the applied
# list back from the marker.
EXTRA_PATCHES=()
[ "${EVQ_OOM:-0}" = "1" ] && EXTRA_PATCHES+=(oom_fault.patch)
[ "${EVQ_OOM_RED:-0}" = "1" ] && EXTRA_PATCHES+=(oom_red.patch)

git -C "$SUBMODULE" apply --check "$RIG_DIR/radio_stub.patch"
git -C "$ESP32_REPO" apply --check "$RIG_DIR/r2p2-esp32.patch"
git -C "$SUBMODULE" apply "$RIG_DIR/radio_stub.patch"
git -C "$ESP32_REPO" apply "$RIG_DIR/r2p2-esp32.patch"
for p in "${EXTRA_PATCHES[@]}"; do
  git -C "$SUBMODULE" apply "$RIG_DIR/$p"
done

cp "$RIG_DIR/rig_injector.c" "$ESP32_REPO/components/picoruby-esp32/rig_injector.c"
cp "$RIG_DIR/sdkconfig.qemu_ble_evq" "$ESP32_REPO/sdkconfigs/qemu_ble_evq"
mkdir -p "$ESP32_REPO/storage/home"
cp "$RIG_DIR/rigapp.rb" "$ESP32_REPO/storage/home/app.rb"

# libmruby is a prebuilt archive; the gem sources just changed and the
# rig define appeared, so force a clean rake build (idf.py won't).
rm -rf "$SUBMODULE/build/esp32-picoruby" "$SUBMODULE/build/esp32-femtoruby"

printf '%s\n' "${EXTRA_PATCHES[@]}" > "$MARKER"
echo "[qemu-ble-evq] applied to $ESP32_REPO${EXTRA_PATCHES[*]:+ (+ ${EXTRA_PATCHES[*]})}"
