#!/usr/bin/env bash
# Apply the qemu-ble-evq overlay to the R2P2-ESP32 working copy and the
# picoruby submodule inside it. Working-copy only — never commit these.
# revert.sh undoes everything; a marker file makes both idempotent.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_ROOT="$(cd "$RIG_DIR/../.." && pwd)"
ESP32_REPO="${R2P2_ESP32_REPO:-$HARNESS_ROOT/vendor/R2P2-ESP32}"
SUBMODULE="$ESP32_REPO/components/picoruby-esp32/picoruby"
MARKER="$ESP32_REPO/.qemu-ble-evq-applied"
CATCHUP_MARKER="$ESP32_REPO/.qemu-ble-evq-catchup"

[ -d "$SUBMODULE" ] || { echo "picoruby submodule not found at $SUBMODULE" >&2; exit 1; }

if [ -f "$MARKER" ]; then
  echo "[qemu-ble-evq] already applied ($MARKER)"
  exit 0
fi

EXTRA_PATCHES=()
[ "${EVQ_OOM:-0}" = "1" ] && EXTRA_PATCHES+=(oom_fault.patch)
[ "${EVQ_OOM_RED:-0}" = "1" ] && EXTRA_PATCHES+=(oom_red.patch)

# r2p2-esp32-btstack-integration (R2P2-ESP32 #135) lags the NimBLE port in PR #427:
# it neither compiles the VM pump nor sets femtoruby up for BLE, so the link
# fails. r2p2-esp32.patch is cut against the caught-up tree. Once the branch
# carries the catch-up itself, it is skipped here rather than applied twice.
CATCHUP=0
if git -C "$ESP32_REPO" apply --check "$RIG_DIR/r2p2-esp32-catchup.patch" 2>/dev/null; then
  CATCHUP=1
elif ! git -C "$ESP32_REPO" apply -R --check "$RIG_DIR/r2p2-esp32-catchup.patch" 2>/dev/null; then
  echo "[qemu-ble-evq] r2p2-esp32-catchup.patch neither applies to nor is already in $ESP32_REPO" >&2
  exit 1
fi

git -C "$SUBMODULE" apply --check --ignore-whitespace "$RIG_DIR/radio_stub.patch"
if [ "$CATCHUP" = 1 ]; then
  git -C "$ESP32_REPO" apply "$RIG_DIR/r2p2-esp32-catchup.patch"
fi
if ! git -C "$ESP32_REPO" apply --check "$RIG_DIR/r2p2-esp32.patch"; then
  if [ "$CATCHUP" = 1 ]; then
    git -C "$ESP32_REPO" apply -R "$RIG_DIR/r2p2-esp32-catchup.patch"
  fi
  exit 1
fi
git -C "$SUBMODULE" apply --ignore-whitespace "$RIG_DIR/radio_stub.patch"
git -C "$ESP32_REPO" apply "$RIG_DIR/r2p2-esp32.patch"
for p in "${EXTRA_PATCHES[@]}"; do
  git -C "$SUBMODULE" apply "$RIG_DIR/$p"
done

cp "$RIG_DIR/rig_injector.c" "$ESP32_REPO/components/picoruby-esp32/rig_injector.c"
cp "$RIG_DIR/sdkconfig.qemu_ble_evq" "$ESP32_REPO/sdkconfigs/qemu_ble_evq"
mkdir -p "$ESP32_REPO/storage/home"
if [ "${EVQ_FLOOD_DRAIN:-}" = "hb" ]; then
  sed 's/FLOOD_DRAIN_ON_HEARTBEAT_ONLY = false/FLOOD_DRAIN_ON_HEARTBEAT_ONLY = true/' "$RIG_DIR/rigapp.rb" > "$ESP32_REPO/storage/home/app.rb"
else
  cp "$RIG_DIR/rigapp.rb" "$ESP32_REPO/storage/home/app.rb"
fi

# libmruby is a prebuilt archive; the gem sources just changed and the
# rig define appeared, so force a clean rake build (idf.py won't).
rm -rf "$SUBMODULE/build/esp32-picoruby" "$SUBMODULE/build/esp32-femtoruby"

if [ "$CATCHUP" = 1 ]; then
  : > "$CATCHUP_MARKER"
fi
: > "$MARKER"
for p in "${EXTRA_PATCHES[@]}"; do
  echo "$p" >> "$MARKER"
done
echo "[qemu-ble-evq] applied to $ESP32_REPO${EXTRA_PATCHES[*]:+ (+ ${EXTRA_PATCHES[*]})}$([ "$CATCHUP" = 1 ] && echo " (+ catch-up)")"
