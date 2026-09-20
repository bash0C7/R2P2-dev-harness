# iOS Dev Harness App — Phase 1 Implementation Plan (BLE UART + DFU on Pico 2 W)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Pico 2 W R2P2 firmware a working BLE transport for application-code
deployment (upload/replace `/home/app.rb`, or a REPL) that does not depend on USB CDC
serial, so a future iOS companion app has something real to talk to over CoreBluetooth.
This phase deliberately stops at the firmware/harness boundary — no iOS code, no Xcode
project — because that work needs a physical iPhone/iPad and Xcode, neither available in
this session.

**Architecture:** `picoruby-ble` and `picoruby-ble-uart` (Nordic UART Service) are
*already* compiled into the stock Pico 2 W R2P2 build (`build_config/r2p2-picoruby-pico2_w.rb`
has `conf.gem core: 'picoruby-ble'` / `'picoruby-ble-uart'` upstream — verified by cloning
`picoruby/picoruby` at `65b7ae6`, see `docs/research/picoruby-ble-dfu-survey.md`). What's
missing is (1) `picoruby-dfu`, the A/B-slot OTA updater whose `DFU::Updater#receive(io)`
is transport-agnostic and explicitly designed to take a `BLE::UART` instance as `io`, and
(2) a resident script that runs `BLE::UART` and dispatches incoming data to either a
`Sandbox`-based REPL (upstream's `example/ble_irb.rb` is the template) or a
`DFU::Updater` for whole-file replacement. This plan adds both, entirely in Ruby plus a
one-line build_config overlay change — no new C code, because the C-level BLE stack
(BTstack + CYW43 on rp2040) is already there.

**Tech Stack:** Ruby (mrblib scripts run on-device), the harness's existing
`rake setup`/`refresh`/`rp2040:build` pipeline, `picoruby-picotest` for whatever part of
the dispatch logic can be tested without a real radio (per docs/spec.md §5's host-layer
pattern).

**Spec:** [docs/superpowers/specs/2026-09-20-ios-dev-harness-app-design.md](../specs/2026-09-20-ios-dev-harness-app-design.md)

## Global Constraints

- No Python (repo-wide rule, unrelated to BLE but still applies to any host-side helper written in this phase).
- No new C code in this phase. `picoruby-ble` / `picoruby-ble-uart` are already in the pico2_w build; the only firmware-build change is adding `picoruby-dfu` via `conf.gem core:`.
- `picoruby-dfu` updates the **Ruby application layer** (`/home/app.rb`/`.mrb` or the A/B slots), never the R2P2 C runtime (`vendor/picoruby`'s `.uf2`). Do not conflate the two anywhere in code, comments, or docs written in this phase.
- This session has no physical Pico 2 W attached and no `arm-none-eabi-gcc` toolchain confirmed present — Task 1's build step and every task after it that needs real hardware must be run in a session that has the board (per CLAUDE.md: "Pico 2 W は Claude が触る", "完了の線引きは実機"). Do not claim a task is done from source-reading alone.
- iOS-side work (a `R2P2-ios-workbench` sibling repo, Swift/CoreBluetooth code, Xcode builds) is out of this plan entirely. Creating a new repository is a decision for the user, not something to do unprompted (see spec's 決定事項 table). This plan only prepares the firmware side a future iOS client would talk to.

## File Structure (this phase)

```
rakelib/vendor.rake            modified — vendor:overlay gains a step that appends
                                `conf.gem core: 'picoruby-dfu'` to the generated
                                build_config shim (docs/spec.md §3's shim mechanism)
examples/rp2040/ble_dev_bridge.rb   new — BLE UART peripheral loop dispatching to
                                     Sandbox (REPL) or DFU::Updater (file replace)
examples/rp2040/ble_dev_bridge_test.rb  new — host test for the dispatch logic only
docs/research/picoruby-ble-dfu-survey.md  already added in this same PR (research, not code)
```

`docs/spec.md` is intentionally **not** touched in this phase — per its own §6/§9
convention, a new "罠" section only gets added once something has actually been run on
real hardware (Task 3). Writing it now would be documenting untested claims.

---

## Task 1: Add `picoruby-dfu` to the pico2_w build overlay

`picoruby-dfu` exists upstream but is absent from every build_config and gembox (confirmed
by `grep -rl picoruby-dfu build_config/` on the shallow clone — no hits). The harness
never edits `vendor/picoruby`'s tracked build_config directly except through the shim
mechanism described in docs/spec.md §3 (the same mechanism used for `Machine.usb_boot`'s
firmware-patches/ approach conceptually, though this is a build_config line, not a C
patch).

**Files:**
- Modify: `rakelib/vendor.rake` (the `vendor:overlay` task / shim generation)

**Interfaces:**
- Consumes: whatever `vendor:overlay` currently does to produce `vendor/picoruby/build_config/r2p2-picoruby-pico2_w.rb` as a shim over the upstream original (docs/spec.md §3).
- Produces: a pico2_w build that includes `picoruby-dfu`, consumed by Task 2's script at runtime and by `rake rp2040:build` in Step 3 below.

- [ ] **Step 1: Read the current `vendor:overlay` implementation**

Run: `grep -n "overlay" rakelib/vendor.rake` and read the surrounding method. Confirm
exactly how it decides what to append to the generated shim (this needs to be understood
before editing it — do not guess at the shim's structure).

- [ ] **Step 2: Add the `picoruby-dfu` line to whatever the overlay appends**

The change should be additive and minimal: one more `conf.gem core: 'picoruby-dfu'` line
in the generated shim, alongside whatever `conf.gem gemdir:` lines already get appended
for this harness's own `gems/`. Do not duplicate or reorder the existing upstream gem
lines the shim loads via `load` (per §3, the harness must never diverge from upstream's
own build_config beyond appending).

- [ ] **Step 3: `rake setup` (or `rake refresh` if `vendor/picoruby` already exists) then `rake rp2040:build`**

Requires `arm-none-eabi-gcc`. If this session's environment lacks it, stop here and note
the gap rather than guessing at the outcome — this step needs a session that already runs
`rp2040:build` successfully (i.e. one with the board-adjacent toolchain set up, per
CLAUDE.md).

Expected: the build succeeds and `picoruby-dfu`'s declared dependencies
(`picoruby-yaml`, `picoruby-vfs`, `picoruby-crc`, `picoruby-pack`/`mruby-pack`) resolve
from gemboxes already pulled in by `r2p2-picoruby-pico2_w.rb` (`stdlib`, `peripherals`,
`peripheral_utils`, `networking` — unconfirmed until this step actually runs). If a
dependency is missing, the build_config gembox list is missing one, not `picoruby-dfu`
itself; add the specific missing `conf.gem core:` line in the same overlay step and
re-run.

- [ ] **Step 4: Commit**

```bash
git add rakelib/vendor.rake
git commit -m "feat(rp2040): enable picoruby-dfu in the pico2_w build overlay

picoruby-ble and picoruby-ble-uart are already in upstream's
r2p2-picoruby-pico2_w.rb build_config. picoruby-dfu (A/B-slot OTA,
transport-agnostic receive(io)) is not, and is the piece Task 2's
BLE bridge script needs to accept whole-file app updates over
BLE::UART. See docs/research/picoruby-ble-dfu-survey.md."
```

---

## Task 2: `examples/rp2040/ble_dev_bridge.rb` — BLE UART + REPL/DFU dispatch

Upstream's `mrbgems/picoruby-ble-uart/example/ble_irb.rb` is a working BLE REPL (feeds
each line to a `Sandbox`, notifies the result back). This task adapts that pattern to
also recognize a DFU binary payload on the same link, so one BLE connection can serve
both "run this one-liner" and "replace `/home/app.rb` with this file" without the iOS
side needing two separate services.

**Files:**
- Create: `examples/rp2040/ble_dev_bridge.rb`
- Create: `examples/rp2040/ble_dev_bridge_test.rb`

**Interfaces:**
- Consumes: `BLE::UART` (upstream, already in the pico2_w build), `DFU::Updater` (Task 1), `Sandbox` (already used by upstream's `ble_irb.rb`, confirmed present in the shell gembox R2P2 already ships).
- Produces: a `/home/`-deployable script; no other code in this repo calls it yet (it's an example a developer runs manually via `rake rp2040:upload`/`run`, same as every other file in `examples/rp2040/`).

- [ ] **Step 1: Decide the framing rule and write it down before coding**

The two payload shapes need to be told apart on one `BLE::UART#gets_nonblock`/
`#read_nonblock` stream:
- A REPL line: arbitrary text ending in `\n`.
- A DFU payload: starts with the 4-byte magic `"DFU\0"` (binary, not line-oriented — `DFU::Updater.expected_size(buf)` from `mrblib/updater.rb` already exists to tell the caller how many total bytes to wait for once the header is visible).

Rule: peek at the first 4 bytes of newly arrived data. If they equal `DFU::Updater::MAGIC`,
switch this connection into DFU mode (buffer until `DFU::Updater.expected_size` bytes are
available, then hand the whole buffer to a `DFU::Updater.new(path: "/home/app.rb").receive(io)`
call via a small buffer-backed IO — `BLE::UART::BufferIO` from `mrblib/ble_uart.rb` is
exactly this adapter and already exists). Otherwise treat arriving data as line-oriented
REPL input, same as `ble_irb.rb`.

- [ ] **Step 2: Write `examples/rp2040/ble_dev_bridge.rb`**

Structure (based on `ble_irb.rb`, extended with the DFU branch from Step 1):

```ruby
require 'ble'
require 'dfu'

uart = BLE::UART.new(name: "R2P2")
sandbox = Sandbox.new('ble-dev-bridge')
mode = :repl
dfu_buf = +""

uart.start do
  if mode == :repl
    if (chunk = uart.read_nonblock(4)) && chunk == DFU::Updater::MAGIC
      mode = :dfu
      dfu_buf = chunk.dup
    elsif chunk
      # not DFU magic: treat as the start of a REPL line, re-queue via gets_nonblock
      # (exact re-queueing mechanics need to be worked out against BLE::UART's
      # actual buffer API in Step 2 — this sketch is not final code)
    end
  end

  if mode == :repl
    if (line = uart.gets_nonblock) && (code = line.chomp) && !code.empty?
      if sandbox.compile("begin; _ = (#{code}); rescue => _; end; _")
        sandbox.execute
        sandbox.wait(timeout: nil)
        sandbox.suspend
        uart.puts "=> #{sandbox.result.inspect}"
      else
        uart.puts "=> SyntaxError"
      end
    end
  else # :dfu
    dfu_buf << (uart.read_nonblock(256) || "")
    expected = DFU::Updater.expected_size(dfu_buf)
    if expected && dfu_buf.bytesize >= expected
      io = BLE::UART::BufferIO.new(dfu_buf)
      begin
        DFU::Updater.new(path: "/home/app.rb").receive(io)
        uart.puts "OK"
      rescue => e
        uart.puts "ERR #{e.message}"
      end
      mode = :repl
      dfu_buf = +""
    end
  end
end
```

This sketch has a known gap flagged inline (re-queuing the peeked 4 bytes back into the
REPL line buffer when they turn out not to be DFU magic) — resolve it by reading
`BLE::UART`'s actual `@rx_buffer` handling in `mrblib/ble_uart.rb` again at implementation
time rather than guessing further here; do not ship the peek-and-drop version, it would
silently eat 4 bytes of every REPL line.

- [ ] **Step 3: Host test of `DFU::Updater.expected_size` and the mode-switch decision only**

Nothing here touches real BLE or a real Sandbox; both are hardware/board-only. Test just
the pure framing decision (magic-byte detection, `expected_size` accounting) with a fake
buffer, following the stub pattern docs/spec.md §5 already uses for CDC-MIDI's
`write_bytes`.

- [ ] **Step 4: Commit**

```bash
git add examples/rp2040/ble_dev_bridge.rb examples/rp2040/ble_dev_bridge_test.rb
git commit -m "feat(rp2040): example BLE UART bridge dispatching REPL lines or DFU payloads

Adapts picoruby-ble-uart's own example/ble_irb.rb to also recognize a
DFU::Updater payload on the same connection, so app-code replacement
and REPL access can share one BLE::UART link. Framing logic covered
by a host test; the BLE/Sandbox path itself needs real hardware (Task 3)."
```

---

## Task 3: Real Pico 2 W verification (blocked on hardware this session doesn't have)

Per docs/spec.md's own rule ("完了の線引きは実機"), nothing above counts as working until
it runs on a board. This task cannot execute in this session (no Pico 2 W attached, no
confirmed `arm-none-eabi-gcc`) — it is written out for whichever session next has the
hardware.

- [ ] **Step 1: Flash the Task 1 build to a Pico 2 W, upload Task 2's script as `/home/app.rb`**

```bash
rake rp2040:flash
rake rp2040:upload[examples/rp2040/ble_dev_bridge.rb,/home/app.rb]
rake rp2040:run[examples/rp2040/ble_dev_bridge.rb,20]
```

- [ ] **Step 2: Verify the REPL path from a second BLE-capable device**

The Mac or a second Pico running `picoruby-ble-uart`'s `example/ble_uart_central.rb` (or
a BLE scanner app) connects, sends a line like `1 + 1`, and should receive `=> 2` back.
If a second Pico 2 W is available, prefer it — it lets this be verified with the harness's
own Ruby/rake tooling instead of needing a phone or a BLE-capable Mac app.

- [ ] **Step 3: Verify the DFU path**

Send a small `.rb` file wrapped in the DFU header format (docs/research/picoruby-ble-dfu-survey.md
has the byte layout) over the same BLE link. Expect `/home/app.rb` to be replaced and,
after a reboot, the new app to run. Confirm `DFU.confirm` semantics don't unexpectedly
interact with this `path:`-mode write (per the DFU README, `path:` mode skips A/B/meta
entirely — confirm that's still true against the installed gem version, not just the
README).

- [ ] **Step 4: Record whatever broke**

Write findings into `docs/research/picoruby-ble-dfu-survey.md`'s "未検証" section (update
it in place) and, once the whole loop is confirmed working, promote the confirmed
behavior into a new docs/spec.md section (Task 4).

---

## Task 4: docs/spec.md — new section, only after Task 3 lands

Not written now — writing it before Task 3 runs would document unverified claims, which
docs/spec.md's own regará. Once Task 3 is done, add a `## iOS 開発ハーネス向け BLE` (or
similarly named) section mirroring the structure of §6 (rp2040 traps) / §9 (ESP32 traps):
what's confirmed, what surprised, exact commands used.

---

## Task 5: `R2P2-ios-workbench` sibling repo (blocked on a user decision, then on Xcode)

Not started in this plan. Per the spec's 決定事項 table, creating a new repository is the
user's call, and even once created, Swift/Xcode work is entirely outside what this
Linux/Ruby harness session can write or verify. This task exists only as the plan's
explicit handoff point: once Task 3 confirms the BLE UART + DFU loop works on real
hardware, that's the trigger to go ask the user whether to create the sibling repo and
start the iOS CoreBluetooth client against the now-verified wire behavior.

---

## Self-Review Notes

- **Spec coverage:** the spec's 決定事項 table's "転送経路" and "アプリコード転送" rows
  are directly implemented by Tasks 1-2; "ファーム自体の OTA" is explicitly kept out
  (Global Constraints); "Playground" and "sibling repo" rows are untouched by this
  plan on purpose (spec marks them as later/user-decision items, not this phase's job).
- **No fabricated verification:** every task past Task 2 that would require a physical
  board, a second BLE device, or Xcode is marked blocked rather than described as done.
  Task 2's code is presented as a sketch with one explicitly flagged unresolved gap
  (buffer peek re-queueing) rather than as finished, untested code — writing confident
  final code for a codepath nobody has run would violate the "don't claim it works"
  rule as much as skipping the hardware step would.
- **Deviation from the design doc:** none — this plan is scoped to exactly the design's
  "完了条件" (BLE UART + DFU on real Pico 2 W), which is deliberately narrower than the
  full iOS app the spec describes.
