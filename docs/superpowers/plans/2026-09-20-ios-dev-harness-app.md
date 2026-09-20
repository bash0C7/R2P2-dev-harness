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
build_config/rp2040-pico2_w.rb      modified — gains gemdir: for the new gem below
                                     plus `conf.gem core: 'picoruby-dfu'`
build_config/host-test.rb           modified — gains gemdir: for the new gem below
gems/picoruby-ble-dev-bridge/       new gem — pure framing logic, zero dependency on
                                     BLE/DFU/Sandbox (mrbgem.rake, mrblib/, sig/, test/)
Rakefile                            modified — HARNESS_GEMS gains the new gem's name
examples/rp2040/ble_dev_bridge.rb   new — wires BLE::UART + DFU::Updater + Sandbox
                                     through the new gem's Framer
rakelib/test.rake                   modified — require_name_of now reads mrbgem.rake
                                     with explicit UTF-8 (see the discipline note below)
docs/spec.md                        modified — one bullet added to §5 documenting the
                                     mrbgem.rake/encoding gotcha (not a new numbered
                                     section — that still waits on Task 3's real hardware)
docs/research/picoruby-ble-dfu-survey.md  already added in the previous PR revision
```

**Correction from the first draft of this plan:** Task 1 originally targeted
`rakelib/vendor.rake` (the `vendor:overlay` task). Reading it before editing (as Step 1
already said to do) showed `vendor:overlay` is a thin shim that just `load`s
`build_config/rp2040-pico2_w.rb` — the actual gem list lives entirely in that harness-side
file (and its host-test counterpart), not in the overlay task itself. `rakelib/vendor.rake`
needed no change at all; only the two `build_config/*.rb` files did. Smaller change than
planned, in the direction docs/spec.md §3 already implies (the overlay task is generic;
harness-specific content belongs in `build_config/`).

---

## Task 1: Add `picoruby-dfu` to the pico2_w build, and a dependency-free framing gem — DONE (host-verified; firmware build unverified)

`picoruby-dfu` exists upstream but is absent from every build_config and gembox (confirmed
by `grep -rl picoruby-dfu build_config/` on the shallow clone — no hits).

**What actually needed changing, after reading the code (see the File Structure section's
correction above):** not `rakelib/vendor.rake`, but the two harness-owned build_config
files it loads.

**Files (as built):**
- Modified: `build_config/rp2040-pico2_w.rb` — added `conf.gem gemdir:` for the new
  `picoruby-ble-dev-bridge` gem and `conf.gem core: 'picoruby-dfu'`, both inside the
  existing `MRuby.each_target do |conf| ... end` block, guarded by the same
  `next unless conf.name.start_with?("r2p2-picoruby-pico2_w")` the file already had.
- Modified: `build_config/host-test.rb` — added `conf.gem gemdir:` for
  `picoruby-ble-dev-bridge` only (no `picoruby-dfu`: the new gem has zero dependency on
  it, see Task 2).
- Created: `gems/picoruby-ble-dev-bridge/{mrbgem.rake,mrblib/ble_dev_bridge.rb,sig/ble_dev_bridge.rbs,test/framer_test.rb}`
- Modified: `Rakefile` — `HARNESS_GEMS` gained `picoruby-ble-dev-bridge` so `rake test:host` picks up its `test/`.

**What DONE means here, precisely:**
- `rake setup` (fetch `vendor/picoruby` + submodules) ran successfully in this session.
- `rake test:host` (host build, `gcc`, no `arm-none-eabi-gcc` needed) built the host VM
  with `picoruby-ble-dev-bridge` included and ran its picotest suite: **21 assertions,
  0 failures** (see Task 2's test count — the gem's only content is the `Framer` class).
- `rake test:examples` (mrbc compile-check, still host-only) compiled
  `examples/rp2040/ble_dev_bridge.rb` without a syntax error.
- **NOT done:** `rake rp2040:build` with the new `conf.gem core: 'picoruby-dfu'` line has
  never run — this session has no `arm-none-eabi-gcc` and no Pico 2 W. Whether
  `picoruby-dfu`'s declared dependencies (`picoruby-yaml`, `picoruby-vfs`, `picoruby-crc`,
  `picoruby-pack`/`mruby-pack`) are already satisfied by `r2p2-picoruby-pico2_w.rb`'s
  existing gemboxes (`stdlib`, `peripherals`, `peripheral_utils`, `networking`) is still
  unconfirmed. If a dependency is missing, `rake rp2040:build` will name it in a
  missing-gem error; add the specific `conf.gem core:` line then, don't guess ahead.

- [x] **Step 1: Read `rakelib/vendor.rake`'s overlay task before touching anything** — done; found it delegates entirely to `build_config/rp2040-pico2_w.rb` (see the correction note above).
- [x] **Step 2: Add the gemdir + `picoruby-dfu` lines to the two build_config files**
- [x] **Step 3 (host-only): `rake setup && rake test:host && rake test:examples`** — all green, output captured in this session's transcript.
- [ ] **Step 3b (still open, needs hardware): `rake rp2040:build`** — blocked, see above. Whoever picks this up next should run this before anything else in Task 3.
- [x] **Step 4: Commit** (folded into one commit with Task 2 and the encoding fix below — see the end of this plan for the actual commit message used).

---

## Task 2: BLE UART + REPL/DFU dispatch — DONE (host-verified; the BLE/Sandbox path itself is real-hardware-only)

Upstream's `mrbgems/picoruby-ble-uart/example/ble_irb.rb` is a working BLE REPL (feeds
each line to a `Sandbox`, notifies the result back). This task adapts that pattern to
also recognize a DFU binary payload on the same link, so one BLE connection can serve
both "run this one-liner" and "replace `/home/app.rb` with this file" without the iOS
side needing two separate services.

The first draft of this plan sketched the dispatch logic inline in the example script and
flagged an explicit unresolved gap: peeking 4 bytes to check for the DFU magic, with no
plan for what to do with those bytes if they turned out to belong to an ordinary REPL
line — a peek-and-drop implementation would silently eat 4 bytes off the front of every
REPL line. **Building it for real forced that gap closed**, by not doing a "peek": the
gem accumulates every byte it's given in its own buffer and only classifies the buffer's
*current full contents* (never bytes already consumed and discarded), so nothing is ever
looked at then thrown away undecided.

**Files (as built):**
- `gems/picoruby-ble-dev-bridge/mrbgem.rake` — no dependency declared, matching
  `picoruby-usb-peripheral`'s "器、依存なし" shape (docs/spec.md §3). Comments in this
  file are plain ASCII on purpose (see the discipline note below).
- `gems/picoruby-ble-dev-bridge/mrblib/ble_dev_bridge.rb` — `BleDevBridge::Framer`, a
  small state machine (`:repl` / `:dfu`) over one owned buffer:
  - `#feed(bytes, &dfu_total)` appends `bytes` (or nothing, if `nil`) to the internal
    buffer, then either extracts a complete `\n`-terminated REPL line, switches to `:dfu`
    mode when the buffer's start matches `DFU::Updater::MAGIC` (`"DFU\0"`, duplicated here
    as a literal — deliberately not `require 'dfu'`, see below), or (in `:dfu` mode) asks
    the caller-supplied `dfu_total` block how many bytes the full payload needs and
    extracts it once enough have arrived.
  - Returns at most one decoded unit (`[:line, str]` or `[:dfu_payload, bytes]`) per call;
    the caller loops, feeding `nil` on subsequent calls, until `feed` returns `nil`, to
    drain multiple units that arrived in one BLE packet.
  - **No `require 'ble'` / `require 'dfu'` / `require 'sandbox'` anywhere in this gem.**
    The DFU wire format (19-byte header, `expected_size`) is knowledge that belongs to
    `picoruby-dfu`, not to this framer — the caller passes it in as a block. This is the
    same reason `picoruby-usb-peripheral` doesn't know about any concrete USB gem.
- `gems/picoruby-ble-dev-bridge/sig/ble_dev_bridge.rbs` — RBS signature, matching the existing gems' `sig/` convention.
- `gems/picoruby-ble-dev-bridge/test/framer_test.rb` — `Picotest::Test` subclass, 11 test methods / 21 assertions, covering: partial lines across multiple `feed` calls, lines shorter than the 4-byte magic (must not block waiting for more bytes), magic split across two `feed` calls, waiting while `dfu_total` is still `nil` (mirrors `DFU::Updater.expected_size`'s real behavior before the header fully arrives), a payload extracted with trailing bytes of the *next* unit already in the same chunk (the direct test of the closed gap), and mode returning to `:repl` after a payload so the next REPL line parses normally.
- `examples/rp2040/ble_dev_bridge.rb` — the actual wiring: `require 'ble'`, `require 'dfu'`, `require 'ble_dev_bridge'`; builds a `BLE::UART.new(name: "R2P2")`, a `Sandbox.new('ble-dev-bridge')`, and a `BleDevBridge::Framer.new`; inside `uart.start do ... end`, reads once per tick with `uart.read_nonblock`, feeds it to the framer in a `loop` (passing `nil` after the first iteration) until `feed` returns `nil`, and dispatches `:line` to a `run_repl_line` helper (same `Sandbox#compile`/`#execute`/`#result` shape as upstream's `ble_irb.rb`) or `:dfu_payload` to a `run_dfu_payload` helper (`BLE::UART::BufferIO.new(payload)` fed into `DFU::Updater.new(path: "/home/app.rb").receive(io)`, `path:` mode so this stays a fast-iteration overwrite rather than an A/B-slot release).

**What DONE means here, precisely:**
- `rake test:host` ran `BleDevBridgeFramerTest`: **21 assertions, 0 failures, 0 errors, 0 crashes**, on the real picoruby host VM (not just a CRuby syntax check).
- `rake test:examples` compiled `examples/rp2040/ble_dev_bridge.rb` with the real `mrbc` (Prism-based parser) with no error.
- **NOT done, and not attempted:** actually running `examples/rp2040/ble_dev_bridge.rb`. `BLE::UART.new` powers on BTstack/CYW43 hardware that only exists on the rp2040 port — running it on this session's host VM would not exercise anything meaningful (there is no BLE radio to power on) and could only produce a misleading pass or an uninformative crash. This is exactly the boundary Task 3 exists to cross with real hardware; simulating it here would violate the "don't fabricate verification" rule as much as skipping it silently would.

- [x] **Step 1: Decide the framing rule** — done as `BleDevBridge::Framer`, described above (own-buffer design, not peek-and-drop).
- [x] **Step 2: Write the gem + the example script** — done, files listed above.
- [x] **Step 3: Host test the framing logic** — done, 21/21 assertions passing.
- [x] **Step 4: Commit** — folded into one commit together with Task 1 and the encoding fix (see below for the actual message).

### A bug found while doing this (not originally in this plan): `mrbgem.rake` must stay ASCII

Adding `gems/picoruby-ble-dev-bridge/mrbgem.rake` with a Japanese-language comment first
made `rake test:host` **crash entirely** with `ArgumentError: invalid byte sequence in
US-ASCII`, not on this gem's own test run but on the *next* one processed (whichever gem
happens to come after it in `Rakefile`'s `HARNESS_GEMS` array) — misleading if you don't
already know where to look. Root cause: `rakelib/test.rake`'s `require_name_of` does
`File.read(rake_file)` with no explicit encoding, so Ruby uses the locale
(`LANG`/`LC_ALL`)-dependent default external encoding; this session's locale is empty, so
that default is US-ASCII, and any non-ASCII byte in *any* gem's `mrbgem.rake` (not just the
new one) makes the read raise. Fixed by making the read explicit (`encoding: "UTF-8"`) and
keeping this gem's `mrbgem.rake` itself in plain ASCII (matching every existing
`mrbgem.rake` in the repo — only `mrblib/`'s comments are Japanese by convention). Written
up as a standing rule in docs/spec.md §5 and in this feature's design spec's new "作業の規律" section, since it applies to every future gem, not just this one.

**Files:**
- Modified: `rakelib/test.rake` (`require_name_of`, one line + a comment)
- Modified: `docs/spec.md` (§5, one new paragraph)
- Modified: `docs/superpowers/specs/2026-09-20-ios-dev-harness-app-design.md` (new "作業の規律" section)

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
goes against docs/spec.md's own convention for its numbered sections. Once Task 3 is
done, add a `## iOS 開発ハーネス向け BLE` (or similarly named) section mirroring the
structure of §6 (rp2040 traps) / §9 (ESP32 traps): what's confirmed, what surprised,
exact commands used. (A separate, small, general-purpose bullet already landed in §5 in
this phase — see the `mrbgem.rake`/encoding note above — but that's an unrelated existing
section, not this new one.)

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
  are directly implemented by Tasks 1-2 (now done, host-verified); "ファーム自体の OTA"
  is explicitly kept out (Global Constraints); "Playground" and "sibling repo" rows are
  untouched by this plan on purpose (spec marks them as later/user-decision items, not
  this phase's job).
- **No fabricated verification, updated:** Tasks 1-2 are now marked done, but "done"
  means exactly what each task's "What DONE means here" subsection says — host build +
  picotest + mrbc compile-check green, real BLE/DFU/hardware behavior still entirely
  unverified. Task 2's earlier explicitly-flagged gap (peek-and-drop losing bytes) is
  closed for real, not just written around: `BleDevBridgeFramerTest` has a dedicated
  test (`test_bytes_after_a_dfu_payload_in_the_same_chunk_are_kept_for_the_next_feed`)
  that would fail if the implementation dropped or misplaced bytes at a mode boundary.
  Task 3 onward remain marked blocked, unchanged.
- **Deviation from the design doc:** the design doc (and this plan's first draft) assumed
  `rakelib/vendor.rake` needed a code change; reading it before editing showed the real
  surface was two `build_config/*.rb` files instead (see the File Structure section's
  correction). Also new relative to the first draft: an unplanned bug fix
  (`rakelib/test.rake`'s `require_name_of` encoding) and a `docs/spec.md` §5 addition,
  both found only by actually running `rake test:host` rather than reading the code —
  the kind of thing that stays invisible until something is actually executed.
