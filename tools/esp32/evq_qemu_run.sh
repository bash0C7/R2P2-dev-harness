#!/usr/bin/env bash
# Boot R2P2-ESP32 under QEMU with the qemu-ble-evq rig applied and collect
# the BLE event-path log (judged by tools/esp32/evq_verdict.rb).
#
# Usage: evq_qemu_run.sh <mrubyc|mruby> <logfile>
#
# Modeled on R2P2-ESP32's scripts/qemu_boot_check.sh (UART console via
# sdkconfigs/qemu, ADC eFuse bypass, capped PSRAM). Run from the
# R2P2-ESP32 checkout with the IDF env exported. Unlike the boot check,
# this run waits until the rig's injector finishes (last inject line),
# then keeps QEMU alive for a grace period so late deliveries still land
# in the log — the verdict, not this script, decides pass/fail.
set -uo pipefail

VM="${1:?Usage: $0 <mrubyc|mruby> <logfile>}"
LOGFILE="${2:?Usage: $0 <mrubyc|mruby> <logfile>}"
BUILD_DIR="${EVQ_BUILD_DIR:-build-qemu-evq}"
RUN_TIMEOUT="${EVQ_RUN_TIMEOUT:-420}"
# The injector logs this once, after its last insertion (rig_injector.c).
DONE_PATTERN="${EVQ_DONE_PATTERN:-\\[rig\\] inject done}"
# Extra seconds after the last inject: covers the worst legitimate RED
# latency (~1s heartbeat) with margin, so "lost" means lost.
GRACE_SECONDS="${EVQ_GRACE_SECONDS:-10}"
FAILURE_PATTERN='assert failed|no such vaddr|Guru Meditation|calibration efuse version does not match|Rebooting\.\.\.'

# The rig define must reach both the IDF-compiled port sources and the
# rake-built libmruby (see firmware-patches/qemu-ble-evq/r2p2-esp32.patch).
export PICORUBY_QEMU_EVQ_RIG=1
[ "${EVQ_FLOOD:-0}" = "1" ] && export PICORUBY_QEMU_EVQ_FLOOD=1
[ -n "${EVQ_FLOOD_SPACING_MS:-}" ] && export PICORUBY_QEMU_EVQ_FLOOD_SPACING_MS="$EVQ_FLOOD_SPACING_MS"

# Known Core-1 StoreProhibited boot-loop mitigation (harness docs/spec.md):
# some gem/memory layouts corrupt a TCB right after app_main returns; a
# 16 KiB VM task stack has made it disappear on QEMU and on the board.
export PICORB_TASK_STACK_SIZE="${EVQ_TASK_STACK_SIZE:-16384}"

# The NimBLE default heap (172 KiB) assumes the controller's static
# buffers share dram0; the rig disables the controller, so take the
# room back — compiling rigapp.rb on-device needs it (NoMemoryError at
# 172 KiB under the mruby VM).
# Per-VM ceiling on IDF v5.5.4: mruby overflows dram0_0_seg at 220 KiB
# (by ~4 KB) and links at 212 KiB; the femtoruby image is bigger still
# and overflows at 212 KiB (by ~1.2 KB), so it gets 200 KiB.
if [ "$VM" = "mruby" ]; then
  export HEAP_SIZE="${EVQ_HEAP_SIZE:-217088}"
else
  export HEAP_SIZE="${EVQ_HEAP_SIZE:-204800}"
fi

echo "== Configuring ${BUILD_DIR} (PICORB_VM=${VM}) =="
idf.py -B "$BUILD_DIR" \
  -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfigs/qemu_ble_evq;sdkconfigs/qemu" \
  -D SDKCONFIG="$BUILD_DIR/sdkconfig" \
  -D PICORB_VM="$VM" \
  set-target esp32s3

EFUSE_PATH="$BUILD_DIR/qemu_efuse.bin"
if [ ! -f "$EFUSE_PATH" ]; then
  echo "== Burning ADC calibration eFuse (BLK_VERSION_MAJOR=1) =="
  idf.py -B "$BUILD_DIR" qemu efuse-burn --do-not-confirm BLK_VERSION_MAJOR 1
fi

echo "== Building and booting QEMU (log: ${LOGFILE}) =="
idf.py -B "$BUILD_DIR" qemu --qemu-extra-args='-m 8M' > "$LOGFILE" 2>&1 &
QEMU_JOB_PID=$!

result=1
elapsed=0
while [ "$elapsed" -lt "$RUN_TIMEOUT" ]; do
  if grep -qE "$DONE_PATTERN" "$LOGFILE" 2>/dev/null; then
    echo "== Injector finished; ${GRACE_SECONDS}s grace for late deliveries =="
    sleep "$GRACE_SECONDS"
    result=0
    break
  fi
  if grep -qE "$FAILURE_PATTERN" "$LOGFILE" 2>/dev/null; then
    echo "== Failure pattern detected in log =="
    result=1
    break
  fi
  if ! kill -0 "$QEMU_JOB_PID" 2>/dev/null; then
    echo "== idf.py qemu exited before the injector finished =="
    result=1
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ "$elapsed" -ge "$RUN_TIMEOUT" ] && [ "$result" -ne 0 ]; then
  echo "== Timed out after ${RUN_TIMEOUT}s waiting for the injector to finish =="
fi

# Kill only OUR qemu: the invocation embeds this run's build dir in the
# flash-image path, so match on that instead of the bare binary name —
# a bare `pkill -f qemu-system-xtensa` also took down unrelated QEMU
# gates (and even shells whose command line contained the string).
kill "$QEMU_JOB_PID" 2>/dev/null || true
pkill -f "qemu-system-xtensa.*${BUILD_DIR}" 2>/dev/null || true
wait "$QEMU_JOB_PID" 2>/dev/null || true

exit "$result"
