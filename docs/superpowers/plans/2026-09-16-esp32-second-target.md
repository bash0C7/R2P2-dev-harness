# ESP32 as the Second rake Target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ESP32 (M5Stack Chain DualKey) the same `rake <target>:build/flash/upload/run/reboot` interface Pico 2 W already has, by shelling out to `bash0C7/R2P2-ESP32` for build/flash/QEMU and porting stackchan-picoruby's reset+picomodem knowledge into this repo so no runtime dependency on stackchan-picoruby remains.

**Architecture:** `rakelib/esp32.rake` orchestrates two things: (1) shells into a sibling checkout of `R2P2-ESP32` for `build` (mruby VM + a bounded QEMU boot check that repo already ships) and `flash` (esptool); (2) uses this repo's own `tools/esp32/` scripts to `upload`/`run`/`reboot` over the board's serial port, talking the same picoruby-picomodem wire protocol Pico 2 W already uses. Reading `tools/pico2w/picomodem.rb` and `term.rb` end to end found nothing Pico-specific in either — both are generic R2P2-shell protocol code — so this plan promotes them to `tools/common/` first and builds the ESP32 scripts on that shared base instead of duplicating ~360 lines.

**Tech Stack:** Ruby (host), `serialport` gem (already a harness dependency), Minitest (bundled with Ruby, no new dependency) for the new host tests, `R2P2-ESP32`'s own Rake tasks + `scripts/qemu_boot_check.sh` (shelled out to, not vendored).

**Spec:** [docs/superpowers/specs/2026-09-15-esp32-second-target-design.md](../specs/2026-09-15-esp32-second-target-design.md)

## Global Constraints

- No Python. The stackchan-picoruby reset code being ported is Python (`pyserial`); the port must use the `serialport` gem instead (repo-wide rule, see `~/.claude/CLAUDE.md`).
- `MRC_PRISM_ARENA_BLOCK=2048` is required wherever ESP32 build_config is touched (issue #1 / issue #12) — this plan does not touch `R2P2-ESP32`'s build_config itself (that fix already landed there as local commit `e5f5c090`), but must not reintroduce the bug if a build_config is ever added to this repo later.
- Target board is M5Stack Chain DualKey (ESP32-S3, no PSRAM), `R2P2-ESP32` branch `r2p2-esp32-btstack-integration`, VM = `mruby` (i.e. the `picoruby:` namespace in `R2P2-ESP32`'s Rake, `PICORB_VM=mruby`).
- Flashing is esptool-only via `R2P2-ESP32`'s own `rake flash`; this repo never installs or drives ESP-IDF directly.
- stackchan-picoruby dependency removal ("引き剥がし") is explicitly out of scope.
- `gems/`'s USB peripheral library ESP32 support is out of scope.
- Follow the existing rp2040 pattern throughout: `rakelib/<target>.rake` with a `device_tool` helper that runs standalone scripts in `tools/<target>/` as separate processes (`sh "ruby script.rb args"`), not in-process requires from the Rakefile.

---

## File Structure

```
tools/common/term.rb            moved from tools/pico2w/term.rb (unchanged)
tools/common/term_test.rb       new — first tests for Term
tools/common/picomodem.rb       moved from tools/pico2w/picomodem.rb (unchanged)
tools/common/picomodem_test.rb  new — tests for the pure protocol functions
tools/pico2w/rsh.rb             modified — require path only
tools/pico2w/runapp.rb          modified — require path only
tools/pico2w/shell_ok.rb        modified — require path only
tools/pico2w/pmput.rb           modified — require path only
tools/esp32/reset.rb            new — RTS-pulse reset, ported from stackchan-picoruby
tools/esp32/reset_test.rb       new
tools/esp32/pmput.rb            new — ESP32 port-discovery + upload CLI
tools/esp32/rsh.rb              new
tools/esp32/runapp.rb           new
tools/esp32/interrupt.rb        new
tools/esp32/shell_ok.rb         new
rakelib/esp32.rake              new — esp32:build/flash/upload/run/reboot + test:esp32
docs/spec.md                    modified — new ESP32 traps section
```

`tools/esp32/` mirrors `tools/pico2w/`'s shape file-for-file (same CLI contract: `ruby <script> <args> [port]`), except the two protocol modules that moved to `tools/common/`. No new gem dependency.

---

## Task 1: Promote `term.rb` and `picomodem.rb` to `tools/common/`

Both files are pure R2P2-shell protocol code — neither has anything specific to the Pico 2 W board (confirmed by reading them: `term.rb` only answers `\e[6n`/`\e[5n` terminal probes, `picomodem.rb` only implements the picoruby-picomodem wire protocol). ESP32 needs the identical logic, so this task moves them to a shared location instead of duplicating them, before any ESP32-specific code is written.

**Files:**
- Create: `tools/common/term.rb` (moved, content unchanged from current `tools/pico2w/term.rb`)
- Create: `tools/common/picomodem.rb` (moved, content unchanged from current `tools/pico2w/picomodem.rb`)
- Modify: `tools/pico2w/rsh.rb:3` (`require_relative "term"` → `require_relative "../common/term"`)
- Modify: `tools/pico2w/runapp.rb:3` (same)
- Modify: `tools/pico2w/shell_ok.rb:7` (same)
- Modify: `tools/pico2w/pmput.rb:3` (`require_relative "picomodem"` → `require_relative "../common/picomodem"`)
- Delete: `tools/pico2w/term.rb`, `tools/pico2w/picomodem.rb` (superseded by the move)

**Interfaces:**
- Produces: `Term.answer(sp, buf)`, `Term.settle(sp, quiet:, limit:)` at `tools/common/term.rb` — used by Task 2's tests and by `tools/esp32/rsh.rb`/`runapp.rb`/`shell_ok.rb` in Task 5.
- Produces: `Deploy::Picomodem.upload(src:, dst:, port:, baud:, boot_timeout:, attempts:, stdout:)`, `Deploy::Picomodem.settle`, `.offer_file_write`, `.send_chunks`, `.crc16`, `.make_frame`, `.recv_frame`, `.answer_queries` at `tools/common/picomodem.rb` — used by Task 3's tests and by `tools/esp32/pmput.rb` in Task 5.

- [ ] **Step 1: Move the two files with git, preserving history**

```bash
mkdir -p tools/common
git mv tools/pico2w/term.rb tools/common/term.rb
git mv tools/pico2w/picomodem.rb tools/common/picomodem.rb
```

- [ ] **Step 2: Update the four require paths**

In `tools/pico2w/rsh.rb`, `tools/pico2w/runapp.rb`, `tools/pico2w/shell_ok.rb`, change:
```ruby
require_relative "term"
```
to:
```ruby
require_relative "../common/term"
```

In `tools/pico2w/pmput.rb`, change:
```ruby
require_relative "picomodem"
```
to:
```ruby
require_relative "../common/picomodem"
```

- [ ] **Step 3: Smoke-test that every touched file still loads (no hardware needed)**

Run:
```bash
ruby -c tools/common/term.rb tools/common/picomodem.rb \
  tools/pico2w/rsh.rb tools/pico2w/runapp.rb tools/pico2w/shell_ok.rb tools/pico2w/pmput.rb
ruby -e 'require_relative "tools/common/term"; require_relative "tools/common/picomodem"; puts "ok"'
```
Expected: every `ruby -c` line prints `Syntax OK`, and the require line prints `ok` with no `LoadError`.

- [ ] **Step 4: Commit**

```bash
git add -A tools/common tools/pico2w
git commit -m "refactor(tools): promote term.rb and picomodem.rb to tools/common/

Neither file has anything Pico 2 W-specific — both implement the R2P2
shell's terminal-probe and picomodem wire protocols, which ESP32 needs
verbatim. Move them ahead of adding tools/esp32/ instead of duplicating
~360 lines of protocol code."
```

**Note for whoever next has Pico 2 W hardware free:** this task changes zero behavior (pure move + require-path edits), so it doesn't block ESP32 work, but a quick `rake rp2040:upload[<any .rb>]` real-device smoke check is good practice whenever the board is next available.

---

## Task 2: Host tests for `tools/common/term.rb`

Neither `tools/pico2w/` nor `tools/common/` has ever had a plain-Ruby test file before. This task establishes the pattern using Minitest (bundled with Ruby — confirmed present via `ruby -e "require 'minitest/autorun'"`), no new dependency.

**Files:**
- Create: `tools/common/term_test.rb`

**Interfaces:**
- Consumes: `Term.answer(sp, buf)`, `Term.settle(sp, quiet:, limit:)` from Task 1.

- [ ] **Step 1: Write the failing tests**

```ruby
# tools/common/term_test.rb
require "minitest/autorun"
require_relative "term"

class TermTest < Minitest::Test
  class FakeSerial
    attr_reader :written

    def initialize(chunks = [])
      @written = []
      @chunks  = chunks
    end

    def write(s)
      @written << s
    end

    def read
      @chunks.shift
    end
  end

  def test_answer_replies_to_a_cursor_query
    sp  = FakeSerial.new
    buf = "\e[6n".dup
    sent = Term.answer(sp, buf)
    assert_equal 1, sent
    assert_equal [Term::CURSOR_REPLY], sp.written
    assert_equal "", buf
  end

  def test_answer_replies_to_a_dsr_query
    sp  = FakeSerial.new
    buf = "\e[5n".dup
    sent = Term.answer(sp, buf)
    assert_equal 1, sent
    assert_equal [Term::DSR_REPLY], sp.written
  end

  def test_answer_handles_multiple_queries_in_one_buffer
    sp  = FakeSerial.new
    buf = "noise\e[6nmore\e[5nend".dup
    sent = Term.answer(sp, buf)
    assert_equal 2, sent
    assert_equal [Term::CURSOR_REPLY, Term::DSR_REPLY], sp.written
    assert_equal "noisemoreend", buf
  end

  def test_answer_returns_zero_when_nothing_to_answer
    sp  = FakeSerial.new
    buf = "plain text".dup
    assert_equal 0, Term.answer(sp, buf)
    assert_empty sp.written
  end

  def test_settle_answers_then_returns_once_quiet
    sp = FakeSerial.new(["\e[6n", nil, nil, nil, nil])
    pending = Term.settle(sp, quiet: 0.05, limit: 1.0)
    assert_includes sp.written, Term::CURSOR_REPLY
    assert_equal "", pending
  end
end
```

- [ ] **Step 2: Run it to make sure it fails first if term.rb were missing (sanity check the harness), then confirm it passes**

Run:
```bash
ruby tools/common/term_test.rb
```
Expected: `5 runs, N assertions, 0 failures, 0 errors`.

- [ ] **Step 3: Commit**

```bash
git add tools/common/term_test.rb
git commit -m "test(tools): add the first Minitest coverage for Term"
```

---

## Task 3: Host tests for `tools/common/picomodem.rb`'s pure functions

`crc16`, `make_frame`, `recv_frame`, and `answer_queries` don't touch a real serial port — they're pure framing logic and are the part of the picomodem protocol safe to verify without hardware. `upload`, `reset_and_reopen`, and `await_shell` stay real-device-only (Task 8).

**Files:**
- Create: `tools/common/picomodem_test.rb`

**Interfaces:**
- Consumes: `Deploy::Picomodem.crc16`, `.make_frame`, `.recv_frame`, `.answer_queries` from Task 1.

- [ ] **Step 1: Write the failing tests**

```ruby
# tools/common/picomodem_test.rb
require "minitest/autorun"
require "stringio"
require_relative "picomodem"

class PicomodemTest < Minitest::Test
  PM = Deploy::Picomodem

  def test_crc16_is_stable_for_the_same_input
    assert_equal PM.crc16("hello"), PM.crc16("hello")
  end

  def test_crc16_differs_for_different_input
    refute_equal PM.crc16("hello"), PM.crc16("world")
  end

  def test_make_frame_round_trips_through_recv_frame
    frame = PM.make_frame(PM::FILE_WRITE, "payload")
    io = StringIO.new(frame)
    cmd, body = PM.recv_frame(io, timeout: 1.0)
    assert_equal PM::FILE_WRITE, cmd
    assert_equal "payload", body
  end

  def test_recv_frame_rejects_a_corrupted_crc
    frame = PM.make_frame(PM::FILE_WRITE, "payload").b
    frame[-1] = (frame.getbyte(-1) ^ 0xFF).chr
    io = StringIO.new(frame)
    assert_nil PM.recv_frame(io, timeout: 1.0)
  end

  def test_answer_queries_answers_cursor_and_dsr_queries
    class << (sp = Object.new)
      attr_reader :written
      def write(s); (@written ||= []) << s; end
    end
    buf = "\e[6n\e[5n".dup
    replies = PM.answer_queries(sp, buf)
    assert_equal 2, replies
    assert_equal [PM::CURSOR_REPLY, PM::DSR_REPLY], sp.written
  end
end
```

- [ ] **Step 2: Run it to confirm it passes**

Run:
```bash
ruby tools/common/picomodem_test.rb
```
Expected: `5 runs, N assertions, 0 failures, 0 errors`.

(`StringIO` supports `wait_readable`/`read_nonblock` well enough for `recv_frame`'s blocking reads because the whole frame is already buffered when the test constructs it — no real timeout is ever hit.)

- [ ] **Step 3: Commit**

```bash
git add tools/common/picomodem_test.rb
git commit -m "test(tools): cover picomodem's frame protocol without a real board"
```

---

## Task 4: `tools/esp32/reset.rb` — RTS-pulse reset, ported from stackchan-picoruby

Ports `stackchan-picoruby`'s `rake r2p2:reset` (`Rakefile:398-411`, Python/pyserial: `dtr=False; rts=True; sleep(0.15); rts=False`) to Ruby + the `serialport` gem this repo already depends on. This is the `esp32:reboot` task's engine (Task 6).

**Files:**
- Create: `tools/esp32/reset.rb`
- Create: `tools/esp32/reset_test.rb`

**Interfaces:**
- Produces: `Reset.pulse(sp, sleep_fn: ->(seconds) { ... })` — used by `rakelib/esp32.rake`'s `esp32:reboot` task (via the script's CLI entry point) in Task 6.

- [ ] **Step 1: Write the failing test**

```ruby
# tools/esp32/reset_test.rb
require "minitest/autorun"
require_relative "reset"

class ResetTest < Minitest::Test
  class FakeSerial
    attr_reader :calls

    def initialize
      @calls = []
    end

    def dtr=(v); @calls << [:dtr=, v]; end
    def rts=(v); @calls << [:rts=, v]; end
  end

  def test_pulse_drives_dtr_low_then_rts_high_then_low
    sp = FakeSerial.new
    slept = []
    Reset.pulse(sp, sleep_fn: ->(seconds) { slept << seconds })
    assert_equal [[:dtr=, 0], [:rts=, 1], [:rts=, 0]], sp.calls
    assert_equal [Reset::PULSE_SECONDS], slept
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby tools/esp32/reset_test.rb`
Expected: `LoadError` or `NameError` (no `tools/esp32/reset.rb` yet).

- [ ] **Step 3: Write the implementation**

```ruby
# tools/esp32/reset.rb
# Pulse RTS to reset a running ESP32 board back to normal execution.
# Ported from stackchan-picoruby's `rake r2p2:reset` (CoreS3, Python/pyserial)
# to Ruby + the serialport gem — same RTS/DTR reset circuit most ESP32 dev
# boards (including Chain DualKey) share.
#   ruby reset.rb [port]
require "serialport"

module Reset
  PULSE_SECONDS = 0.15

  module_function

  # sp: an already-open SerialPort-like object responding to dtr=, rts=.
  # sleep_fn: injected so tests don't burn 0.15 real seconds.
  def pulse(sp, sleep_fn: method(:sleep))
    sp.dtr = 0
    sp.rts = 1
    sleep_fn.call(PULSE_SECONDS)
    sp.rts = 0
  end
end

if $PROGRAM_NAME == __FILE__
  def default_port
    # Same product-name lookup as tools/esp32/*.rb generally (Task 5) — a bare
    # /dev/cu.usbmodem* glob is wrong once a Pico 2 W is also plugged in.
    out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
    ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
    raise "R2P2 board not found on USB (is the ESP32 plugged in?)" if ports.empty?
    ports.first
  end

  port = ARGV[0] || default_port
  sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
  begin
    Reset.pulse(sp)
    puts "[reset] pulsed RTS on #{port}"
  ensure
    sp.close
  end
end
```

- [ ] **Step 4: Run the test again to verify it passes**

Run: `ruby tools/esp32/reset_test.rb`
Expected: `1 run, 2 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add tools/esp32/reset.rb tools/esp32/reset_test.rb
git commit -m "feat(esp32): port stackchan-picoruby's RTS-pulse reset to Ruby

No Python — uses the serialport gem this repo already depends on. The
electrical reset is unverifiable without hardware; the sequencing
(dtr=0, rts=1, pause, rts=0) is covered by a host test with a fake
serial double, matching the CoreS3 sequence stackchan-picoruby already
verified on real hardware."
```

**Real-device note (see Task 8):** whether `ioreg -n "R2P2"` actually matches Chain DualKey's USB product name is unconfirmed without the board attached. `ARGV[0]` already lets a caller pass an explicit port to bypass the lookup if the name doesn't match.

---

## Task 5: `tools/esp32/pmput.rb`, `rsh.rb`, `runapp.rb`, `interrupt.rb`, `shell_ok.rb`

Board-facing CLI wrappers, ported from their `tools/pico2w/` equivalents. Each is a thin script: parse `ARGV`, resolve a port, open it, delegate to `tools/common/term.rb` or `tools/common/picomodem.rb`. There is nothing further to unit-test here beyond Tasks 2-3 (already covering the logic these scripts call) and a syntax/load smoke check — real behavior needs the board (Task 8).

**Files:**
- Create: `tools/esp32/pmput.rb`
- Create: `tools/esp32/rsh.rb`
- Create: `tools/esp32/runapp.rb`
- Create: `tools/esp32/interrupt.rb`
- Create: `tools/esp32/shell_ok.rb`

**Interfaces:**
- Consumes: `Deploy::Picomodem` (Task 1, via `../common/picomodem`), `Term` (Task 1, via `../common/term`).
- Produces: five CLI entry points invoked by `rakelib/esp32.rake`'s `device_tool` helper (Task 6), matching `tools/pico2w`'s CLI contract exactly (`ruby <script> <args...> [port]`).

- [ ] **Step 1: Create `tools/esp32/pmput.rb`**

```ruby
# PicoModem upload to an ALREADY-RUNNING R2P2 shell (no reset pulse).
#   ruby pmput.rb <src> <dst> [port]
require_relative "../common/picomodem"
PM = Deploy::Picomodem

def default_port
  # A bare /dev/cu.usbmodem* glob is wrong once a Pico 2 W is also plugged
  # in: sort order and product name both need checking on real hardware
  # (Task 8) — this filter is a starting point, not yet confirmed.
  out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  if ports.empty?
    raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)"
  end
  ports.first
end

src  = ARGV[0]
dst  = ARGV[1]
port = ARGV[2] || default_port

content = File.binread(src)
payload = [content.bytesize].pack("N") + dst
puts "[pmput] #{src} -> #{dst} (#{content.bytesize} bytes) on #{port}"

serial = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
begin
  serial.write("\r\n")
  PM.settle(serial, $stdout)
  reason = PM.offer_file_write(serial, payload, $stdout, 1)
  abort "[pmput] FAILED: #{reason}" if reason
  PM.send_chunks(serial, content, $stdout)
  puts "[pmput] OK"
ensure
  serial.close
end
```

- [ ] **Step 2: Create `tools/esp32/rsh.rb`**

```ruby
# Send a line to the R2P2 shell and capture output for N seconds.
#   ruby rsh.rb "<command>" [seconds] [port]
require "serialport"
require_relative "../common/term"

def default_port
  out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)" if ports.empty?
  ports.first
end

cmd  = ARGV[0].to_s
secs = (ARGV[1] || "3").to_f
port = ARGV[2] || default_port
sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
sp.read_timeout = 100
Term.settle(sp)
sp.write(cmd + "\r\n") unless cmd.empty?
buf = +""
t0 = Time.now
while Time.now - t0 < secs
  chunk = sp.read
  if chunk && !chunk.empty?
    buf << chunk
    Term.answer(sp, chunk.dup)
  end
  sleep 0.05
end
sp.close
print buf.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
```

- [ ] **Step 3: Create `tools/esp32/runapp.rb`**

```ruby
# Run a script on the R2P2 shell and capture stdout for N seconds, then Ctrl-C.
#   ruby runapp.rb <device path> <seconds> [port]
require "serialport"
require_relative "../common/term"

def default_port
  out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)" if ports.empty?
  ports.first
end

path = ARGV[0]
secs = (ARGV[1] || "20").to_f
port = ARGV[2] || default_port
sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
sp.read_timeout = 100
Term.settle(sp)
sp.write(path + "\r\n")
t0 = Time.now
buf = +""
while Time.now - t0 < secs
  c = sp.read
  if c && !c.empty?
    buf << c
    Term.answer(sp, c.dup)
    $stdout.print c.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
    $stdout.flush
  end
  sleep 0.05
end
sp.write("\x03")
sleep 0.5
sp.close
```

- [ ] **Step 4: Create `tools/esp32/interrupt.rb`**

```ruby
# Send Ctrl-C to the R2P2 shell port, to stop an autostarted /home/app.rb and
# bring the "$>" prompt back.
#   ruby interrupt.rb [port]
port = ARGV[0] || `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort.first
abort "R2P2 board not found on USB" unless port
io = IO.for_fd(IO.sysopen(port, File::RDWR | File::NONBLOCK | File::NOCTTY), autoclose: false)
io.write_nonblock("\x03")
puts "[interrupt] Ctrl-C sent to #{port}"
exit! 0
```

- [ ] **Step 5: Create `tools/esp32/shell_ok.rb`**

```ruby
# Report whether the R2P2 shell answers, without ever wedging this process.
# Prints OK or DEAD and exits 0 / 1.
#
# CAUTION (ESP32-specific, unlike Pico 2 W): opening the serial port at all
# is expected to reset the board (issue #12's known trap), so this check is
# NOT a side-effect-free liveness probe here — every call reboots the board
# and then waits for it to come back up to "$>". Confirm this against real
# hardware in Task 8; if it turns out false, this comment and the timeout
# below need revisiting.
require_relative "../common/term"

def r2p2_ports
  `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
end

dev = ARGV[0] || r2p2_ports.first
unless dev
  puts "DEAD (not enumerated)"
  exit 1
end

r, w = IO.pipe
pid = fork do
  r.close
  begin
    fd = IO.sysopen(dev, File::RDWR | File::NONBLOCK | File::NOCTTY)
    io = IO.for_fd(fd)
    io.write_nonblock("\r\n") rescue nil
    replier = Object.new
    replier.define_singleton_method(:write) { |s| io.write_nonblock(s) rescue nil }
    got = +""
    pending = +""
    40.times do
      chunk = (io.read_nonblock(2048) rescue "")
      got << chunk
      pending << chunk
      Term.answer(replier, pending)
      break if got.include?("$>")
      sleep 0.25
    end
    w.write(got)
  rescue => e
    w.write("ERR #{e.class}")
  end
  w.close
  exit! 0
end
w.close
alive = true
60.times { break if (alive = !Process.waitpid(pid, Process::WNOHANG)) == false; sleep 0.25 }
if alive
  Process.kill("KILL", pid) rescue nil
  Process.waitpid(pid) rescue nil
  puts "DEAD (#{dev}: open wedged)"
  exit 1
end
out = r.read.to_s
r.close
if out.empty? || out.start_with?("ERR")
  puts "DEAD (#{dev}: #{out.empty? ? 'silent' : out})"
  exit 1
end
unless out.include?("$>")
  puts "DEAD (#{dev}: no prompt, got #{out[0, 60].inspect})"
  exit 1
end
puts "OK (#{dev})"
```

Note the loop counts are doubled versus `tools/pico2w/shell_ok.rb` (40×0.25s ≈ 10s read window, 60×0.25s ≈ 15s wait) because opening the port here also triggers a full boot, not just a prompt repaint — tune against real timing in Task 8.

- [ ] **Step 6: Smoke-test that every new file loads without a LoadError**

Run:
```bash
ruby -c tools/esp32/pmput.rb tools/esp32/rsh.rb tools/esp32/runapp.rb tools/esp32/interrupt.rb tools/esp32/shell_ok.rb
ruby -e '
ARGV.replace([])
$LOAD_PATH.unshift("tools/esp32")
require "stringio"
# pmput.rb, rsh.rb, runapp.rb, shell_ok.rb all read ARGV at top level and
# would try to open a real port with no ARGV — only check they parse and
# that their requires resolve, via -c above, which already covers this.
puts "ok"
'
```
Expected: every `ruby -c` line prints `Syntax OK`.

- [ ] **Step 7: Commit**

```bash
git add tools/esp32/pmput.rb tools/esp32/rsh.rb tools/esp32/runapp.rb tools/esp32/interrupt.rb tools/esp32/shell_ok.rb
git commit -m "feat(esp32): board-facing CLI scripts, ported from tools/pico2w

Same CLI contract as tools/pico2w (ruby <script> <args> [port]), built
on the shared tools/common/term.rb and picomodem.rb from the previous
commit. Port-discovery and shell_ok's timing are starting points to be
confirmed against Chain DualKey hardware."
```

---

## Task 6: `rakelib/esp32.rake` — the rake tasks

Wires everything together: `build`/`flash` shell out to the `R2P2-ESP32` sibling repo, `upload`/`run`/`reboot` use Task 4-5's scripts via a `device_tool` helper mirroring `rakelib/rp2040.rake`'s.

**Files:**
- Create: `rakelib/esp32.rake`

**Interfaces:**
- Consumes: `HARNESS_ROOT` (top-level `Rakefile` constant, already defined), `tools/esp32/*.rb` (Task 4-5), `tools/common/*.rb` (Task 1, indirectly via `device_tool`'s scripts).
- Produces: `rake esp32:build`, `esp32:flash`, `esp32:upload[src,dst]`, `esp32:run[app,seconds]`, `esp32:reboot`, `test:esp32` — the last is new, not part of the spec's rake interface, but needed to run Tasks 2-4's tests conveniently.

- [ ] **Step 1: Write `rakelib/esp32.rake`**

```ruby
# ESP32 (M5Stack Chain DualKey) 向けのタスク。
#
# build/flash は bash0C7/R2P2-ESP32 の sibling checkout (branch
# r2p2-esp32-btstack-integration, VM=mruby) にそのまま委ねる。ESP-IDF の
# インストール・保守はこの harness の責務にしない (docs/spec.md 参照)。
# upload/run/reboot はこの harness 自前の tools/esp32/ で picomodem
# プロトコルを直接話す。
namespace :esp32 do
  VM = "mruby".freeze # PICORB_VMS[:picoruby] => :mruby in R2P2-ESP32's Rakefile

  desc "Build the R2P2-ESP32 firmware (mruby VM) and boot-check it under QEMU"
  task :build do
    require_esp32_repo!
    FileUtils.cd(esp32_repo_dir) do
      sh "rake picoruby:build"
      sh "bash scripts/qemu_boot_check.sh #{VM}"
    end
  end

  desc "Flash the last build to the board via esptool"
  task :flash do
    require_esp32_repo!
    FileUtils.cd(esp32_repo_dir) do
      sh "rake flash"
    end
  end

  desc "Copy a local .rb onto the board over PicoModem (/home/app.rb autostarts at boot)"
  task :upload, [:src, :dst] do |_t, args|
    src = args[:src] or raise "usage: rake esp32:upload[<local .rb>,</home/name.rb>]"
    dst = args[:dst] || "/home/#{File.basename(src)}"
    esp32_device_tool "pmput.rb", src, dst
  end

  desc "Run an app on the board and capture its log"
  task :run, [:app, :seconds] do |_t, args|
    app = args[:app] or raise "usage: rake esp32:run[<local .rb>,<seconds>]"
    seconds = args[:seconds] || "20"
    remote = "/home/#{File.basename(app)}"
    esp32_device_tool "pmput.rb", app, remote
    esp32_device_tool "runapp.rb", remote, seconds
  end

  desc "Reset the board (RTS pulse) and wait for the shell"
  task :reboot do
    esp32_device_tool "reset.rb"
  end
end

namespace :test do
  desc "Run the plain-Ruby host tests for tools/common and tools/esp32 (no board needed)"
  task :esp32 do
    Dir[File.join(HARNESS_ROOT, "tools", "common", "*_test.rb"),
        File.join(HARNESS_ROOT, "tools", "esp32", "*_test.rb")].sort.each do |test_file|
      sh "#{RbConfig.ruby.shellescape} #{test_file.shellescape}"
    end
  end
end

# ENV override for a non-standard checkout location, same convention as
# PICORUBY_REPO/PICORUBY_REF in the top-level Rakefile.
def esp32_repo_dir
  ENV["R2P2_ESP32_REPO"] || File.expand_path("../R2P2-ESP32", HARNESS_ROOT)
end

def require_esp32_repo!
  dir = esp32_repo_dir
  unless File.directory?(dir)
    raise "R2P2-ESP32 not found at #{dir}. Clone bash0C7/R2P2-ESP32 as a sibling " \
          "of this repo, or set R2P2_ESP32_REPO=/path/to/R2P2-ESP32."
  end
end

def esp32_device_tool(name, *args)
  script = File.join(HARNESS_ROOT, "tools", "esp32", name)
  raise "#{script} is missing" unless File.file?(script)
  sh "#{RbConfig.ruby.shellescape} #{script.shellescape} #{args.map { |a| a.to_s.shellescape }.join(' ')}"
end
```

- [ ] **Step 2: Run the new host-only test task**

Run: `rake test:esp32`
Expected: both test files from Tasks 2-3 and 4 run and pass (`3 files, N runs, 0 failures, 0 errors` in total across the invocations).

- [ ] **Step 3: Confirm the other esp32 tasks are wired without a board (they should fail cleanly, not crash)**

Run:
```bash
rake esp32:build   # expected: raises "R2P2-ESP32 not found at ..." unless the sibling repo exists at the default path, or actually shells out if it does — either way, must not raise a Ruby NameError/NoMethodError
rake esp32:upload  # expected: raises "usage: rake esp32:upload[...]" (missing src arg), not a crash
```

- [ ] **Step 4: Commit**

```bash
git add rakelib/esp32.rake
git commit -m "feat(esp32): rake esp32:build/flash/upload/run/reboot

build/flash shell out to a sibling R2P2-ESP32 checkout (ENV
R2P2_ESP32_REPO overridable); upload/run/reboot use this repo's own
tools/esp32/. Matches rp2040's rake interface (docs/spec.md §4)."
```

---

## Task 7: docs/spec.md — ESP32 traps section

Adds a section documenting what's now known about ESP32, mirroring §6's rp2040 traps.

**Files:**
- Modify: `docs/spec.md` (append a new `## 9. ESP32 の罠` section — check the current highest section number in the file before numbering, since Task 6 additions or later edits may have changed it since this plan was written)

- [ ] **Step 1: Read the current section numbering**

Run: `grep -n "^## " docs/spec.md`

- [ ] **Step 2: Append the new section** (adjust the number to be one past the last one found in Step 1)

```markdown
## 9. ESP32 の罠

対象: M5Stack Chain DualKey（ESP32-S3、PSRAM無し）。`bash0C7/R2P2-ESP32` branch
`r2p2-esp32-btstack-integration`、VM は `mruby`。build/flash はそちらの rake
タスクへ委ねる（`rake esp32:build` / `flash`、ENV `R2P2_ESP32_REPO` で checkout
先を上書き可能）。

- **シリアルポートを開くだけでリセットされる。** Pico 2 W（RP2350）はDTR/RTSで
  リセットされないので、同じ道具を流用する時は逆の前提になる。`tools/esp32/shell_ok.rb`
  の生存確認さえ、この副作用でボードを再起動させる — Pico 2 Wの「触らずに見る」
  という前提が成立しない
- **ポートを`/dev/cu.usbmodem*`のglobで選ばない。** ESP32が先に並ぶ。`tools/esp32/`
  各scriptは`ioreg -n "R2P2"`で製品名を見て選ぶが、この文字列がChain DualKeyの
  実際のUSB製品名と一致するかは実機未確認（次の一歩）
- **heapが小さい。** PSRAM無しの約180KBで、`MRC_PRISM_ARENA_BLOCK`のデフォルト
  64KB/compiler contextのままだと起動時boot・sandbox(load時)の2つのcompiler
  contextで枯渇し`NoMemoryError` → abort → reboot loop。`R2P2-ESP32`側は
  `MRC_PRISM_ARENA_BLOCK=2048`を`components/picoruby-esp32/build_config/xtensa-esp-picoruby.rb`
  に追加済み（local commit `e5f5c090`、issue #1・#12参照）
- **書き込みはesptoolのみ。** ESP-IDFのフルインストールはこのrepoの責務にしない。
  `rake esp32:build`が内部で`idf.py`を呼ぶのは`R2P2-ESP32`側の環境の話であり、
  このharness自体はESP-IDFを直接扱わない
- **QEMU起動確認が`build`に含まれる。** `R2P2-ESP32`の`scripts/qemu_boot_check.sh`
  （デフォルト300秒、`$> `を見つけたら成功、失敗パターンでも即終了）を実機の前段
  として通す。実機無しでbuildの健全性がある程度わかる
```

- [ ] **Step 3: Commit**

```bash
git add docs/spec.md
git commit -m "docs: add the ESP32 traps section to spec.md"
```

---

## Task 8: Real-device verification (Chain DualKey required — cannot run in this session without the board)

Everything above is code review + host tests. This task is the actual gate per this repo's own rule ("完了の線引きは実機。rake test が green でも実機で走らせるまで動いたと書かない") and issue #12's 完了条件. Run it whenever Chain DualKey is free (the board was in use by another session as of this plan's writing).

- [ ] **Step 1: Confirm the sibling checkout and branch**

```bash
ls ../R2P2-ESP32   # or: echo $R2P2_ESP32_REPO
git -C ../R2P2-ESP32 branch --show-current   # expect: r2p2-esp32-btstack-integration
git -C ../R2P2-ESP32 log -1 --oneline        # expect: e5f5c090 or later (MRC_PRISM_ARENA_BLOCK fix present)
```

- [ ] **Step 2: `rake esp32:build`**

Expected: `rake picoruby:build` succeeds, then `scripts/qemu_boot_check.sh mruby` prints `== Shell prompt reached ==` and exits 0. If it times out or hits a failure pattern, read `../R2P2-ESP32/qemu-boot-mruby.log`.

- [ ] **Step 3: Plug in Chain DualKey, find its actual port**

```bash
ioreg -w 0 -r -n "R2P2" -l | grep IOCalloutDevice
```
If this returns nothing, find the real product name:
```bash
ioreg -p IOUSB -w 0 -l | grep -B5 "IOCalloutDevice" 
```
and fix the `ioreg -n "..."` filter string in every `tools/esp32/*.rb` file (Task 4-5) and in `docs/spec.md`'s new section (Task 7) to match. Commit that fix separately once confirmed.

- [ ] **Step 4: `rake esp32:flash`**

Expected: esptool writes the firmware and the board boots R2P2. Confirm with:
```bash
ruby tools/esp32/shell_ok.rb
```
Expected: `OK (<port>)`. If it hangs, note whether the port-opens-cause-reset trap (docs/spec.md §9) means the fork-based timeout in `shell_ok.rb` needs a longer window than Pico 2 W's — adjust the loop counts (Step 5's comment already flags this) and commit the fix.

- [ ] **Step 5: `rake esp32:upload[<some local .rb>]` then `rake esp32:run[<same file>,10]`**

Write a trivial probe file first:
```ruby
# /tmp/esp32_probe.rb
puts "esp32 probe ok"
```
```bash
rake esp32:upload[/tmp/esp32_probe.rb]
rake esp32:run[/tmp/esp32_probe.rb,10]
```
Expected: the captured output includes `esp32 probe ok`.

- [ ] **Step 6: `rake esp32:reboot`**

Expected: the board resets (LED/boot banner observed) and `tools/esp32/reset.rb` exits 0 without raising.

- [ ] **Step 7: Update docs/spec.md and this plan's Task 4-5 comments with whatever was confirmed or corrected**

Any port-name fix, timing fix, or behavioral surprise found in Steps 3-6 gets written into `docs/spec.md`'s §9 (Task 7) — this is the "実機で踏んだ罠をこのrepoに集約する" goal from the spec's 目的 section, not optional cleanup.

- [ ] **Step 8: Close the loop on issue #12**

```bash
gh issue comment 12 --body "Chain DualKeyで rake esp32:build/flash/upload/run/reboot が通った。詳細はdocs/spec.md §9。"
```
Ask the user before closing issue #12 itself — completion of the harness-side plumbing doesn't necessarily mean every future ESP32 knowledge-gathering goal in that issue is done.

---

## Self-Review Notes

- **Spec coverage:** all four brainstorming decisions (board, flashing, QEMU, source of tooling) are implemented in Task 6; the "既に分かっている罠" trap list from issue #12 is carried into Task 7's spec.md section; the スコープ外 items (gems/ USB peripheral ESP32 support, stackchan-picoruby dependency removal, ESP-IDF full install) are not touched anywhere in Tasks 1-8.
- **Placeholder scan:** no TBD/TODO; every code step has complete, runnable code; Task 8's steps are inherently manual/hardware-gated but each has a concrete command and a concrete expected result, not a vague "verify it works."
- **Type/interface consistency:** `Reset.pulse(sp, sleep_fn:)` (Task 4) is used identically by its test; `Deploy::Picomodem`'s public method names in Task 1's "Produces" list match what Tasks 3 and 5 actually call; `esp32_repo_dir`/`require_esp32_repo!`/`esp32_device_tool` (Task 6) are defined once and used only within `rakelib/esp32.rake`.
- **Deviation from the design doc:** the design doc left "共有できるか実装時に判断する" open for `tools/pico2w/picomodem.rb`. Reading the file in full during planning found it has no Pico-specific logic, so this plan promotes it (and `term.rb`) to `tools/common/` (Task 1) rather than duplicating them — a smaller, safer change than the design doc anticipated, and explicitly permitted by it ("無理に共通化せず" was permission not to share, not a requirement to duplicate).
