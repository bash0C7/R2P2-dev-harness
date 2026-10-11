# Judge a BLE event-path QEMU log from the qemu-ble-evq rig
# (firmware-patches/qemu-ble-evq). The rig's injector task logs one
# summary line, the Ruby test app logs each arrival's seq/inject-time/
# receive-time, and the overlay logs FOREIGN_PUSH when the Ruby queue is
# pushed from outside the VM thread. Pass = every injected seq arrived,
# within max_latency_ms, with no foreign push.
#
# judge_flood and judge_limits judge the optional write-flood and limits
# phases of the same rig. judge_limits asks the two limits the event path
# has: a full ring (EVQ_DEPTH) and a value longer than the event packet
# (VALUE_EVENT_DATA_MAX). It passes when the firmware says so in its log
# and does not punch holes into the stream.
#
# judge_limits_green judges the same run against the byte-ring port (R1): the
# burst, the single overflow log line, the completion status over refused
# results, whole notifications and the disconnect before the burst, each with
# its own derivation; the two checks of later steps come back separately.
#
# judge_control_burst, judge_can_send_now and judge_power_on_states judge
# three more defects of the same limits run; judge_limits_checks returns all
# four verdicts by name, so a partial fix shows which one turned green.
#
# judge_power judges the power case (PICORUBY_QEMU_EVQ_POWER): seven
# hci_power_control steps, each compared with the BTSTACK_EVENT_STATE sequence
# BTstack emits for it (POWER_REFERENCE, measured on the Pico 2 W).
#
# judge_resync judges the resync case (PICORUBY_QEMU_EVQ_RESYNC): after the
# rig's host has reset and synced again, a second BLE.new followed at once by
# advertise must reach ble_gap_adv_start with the host synced.
module EvqVerdict
  # rig_ran is set by judge_limits only: false when the limits phase left no
  # evidence in the log (the device program or the injector never got there), so
  # the verdict says nothing about the firmware.
  Result = Struct.new(:pass, :message, :rig_ran, keyword_init: true)

  INJECT_DONE = /inject done n=(\d+)/
  RECV = /recv seq=(\d+) tin=(\d+) t=(\d+)/
  FOREIGN_PUSH = /FOREIGN_PUSH/
  WRITE_A = /write h=0x42 v="A"/
  WRITE_B = /write h=0x42 v="B"/
  FAULT = /FAULT write/
  FLOOD_DONE = /flood done n=(\d+) rejected=(\d+)/
  FLOOD_RECV = /flood received=(\d+) bytes=(\d+)/
  FLOOD_CRASH = /Fatal error: Out of memory|NoMemoryError|Guru Meditation|abort\(\) was called|Rebooting/
  FLOOD_DROP = /write queue full/
  WLAT = /wlat tin=(\d+) t=(\d+)/
  BURST_DONE = /burst done first=(\d+) last=(\d+)/
  NOTIFY_INJECTED = /notify injected len=(\d+)/
  NOTIF_SEEN = /notif len=(\d+) raw=(\d+)/
  # The firmware's message when the event ring overflows must contain this
  # phrase ("event ring full"), whatever else it says around it.
  RING_OVERFLOW_LOGGED = /event ring full/i
  # The firmware's message when a received value is cut to fit the event
  # packet must contain "truncat" (truncated / truncating / truncation).
  TRUNCATION_LOGGED = /truncat/i
  # What the byte ring answered to the L1 burst (rig_injector.c; the port with the
  # 32-slot ring has no such line).
  BURST_ACCEPTED = /burst accepted=(\d+) refused=(\d+) first_refused=(\d+) budget=(\d+) entry=(\d+)/
  PROC_INJECTED = /proc ([AB]) injected results=(\d+) handle_first=(\d+)/
  COMPLETE_SEEN = /rigapp\] complete (\d+)/
  DSC_SEEN = /rigapp\] dsc (\d+)/
  # Bytes of the event ring that only a GATT completion may use (nimble_owner.c,
  # EVQ_COMPLETION_BYTES = 2 + 9) and the status such a completion carries when a
  # result of its procedure was refused (ATT_ERROR_INSUFFICIENT_RESOURCES).
  EVQ_COMPLETION_RESERVE = 11
  STATUS_INSUFFICIENT_RESOURCES = 0x11
  CONTROL_BURST_DONE = /control done first=(\d+) last=(\d+) h1=(\d+) h2=(\d+)/
  CANSEND_INJECTED = /cansend injected n=(\d+) con_handle=(\d+)/
  EXTRA_STATE_INJECTED = /extra state injected/
  DISC_SEEN = /rigapp\] disc (\d+)/
  CANSEND_SEEN = /rigapp\] cansend/
  STATE_SEEN = /rigapp\] state (\d+)/
  MARK_SEEN = /rigapp\] mark (\d+)/
  CON_HANDLE_NONE = 0xffff
  RESYNC_CONTROL = /rigapp\] resync control/
  RESYNC_SECOND_NEW = /rigapp\] resync second new/
  RESYNC_DONE = /rigapp\] resync done/
  RESYNC_HOST_DONE = /\[rig\] host resync done/
  RESYNC_SYNC_CB = /\[rig\] host sync_cb/
  RESYNC_ADV_START = /\[rig\] ble_gap_adv_start rc=(-?\d+) host_synced=(\d)/
  BLE_HS_ENOTSYNCED = 22
  POWER_BEGIN = /rigapp\] power begin/
  POWER_DONE = /rigapp\] power done/
  POWER_STEP_EVENT = /rigapp\] step (\d+) (state|disc) (\d+)/
  POWER_INJECTED = /power inject disc handle=(\d+) call=(\d+)/
  # BTSTACK_EVENT_STATE values per step: HCI_STATE_OFF=0 INITIALIZING=1
  # WORKING=2 HALTING=3 SLEEPING=4 FALLING_ASLEEP=5. Step 7 also expects the
  # injected DISCONNECTION_COMPLETE (:disc), put into the ring just before the
  # nested power-on; its position relative to the state is not part of the
  # reference, so step 7 is compared as a multiset.
  POWER_REFERENCE = {
    1 => [1, 2],
    2 => [3, 0],
    3 => [0],
    4 => [1, 2],
    5 => [5, 4],
    6 => [1, 2],
    7 => [2, :disc],
  }
  POWER_STEP_NAMES = {
    1 => "power-on",
    2 => "power-off",
    3 => "power-off while off",
    4 => "power-on again",
    5 => "sleep",
    6 => "power-on from sleep",
    7 => "nested power-on with an event in the ring",
  }
  POWER_CALL = /\[rigapp\] step (\d+) call (\w+) t=(\d+)/
  POWER_TIMED_EVENT = /\[rigapp\] step (\d+) (state|disc) (\d+) t=(\d+)/
  POWER_HB = /\[rigapp\] step (\d+) hb t=(\d+)/
  NIMBLE_CALL = /\[rig\] nimble (\w+)(?: handle=(\d+) reason=0x(\h+))?(?: -> (\d+))? power=(\d+)/
  POWER_CALL_STEPS = (3..12).to_a
  POWER_LINK_HANDLE = 51
  POWER_TERMINATE_REASON = 0x13
  # The pump completes a power-off or sleep that has something left to wait for 1000 ms
  # after the call (bt hci.c:5978-5983; measured on the Pico 2 W at 1005 ms, ledger D30).
  # The device program reads the time when it pops the event, so the interval it sees is
  # the deadline plus what lies between the pump and the program: the scheduler pass that
  # runs the pump (MRB_TICK_UNIT 10 ms on the board; the rig builds the same way) and the
  # program's 20 ms poll of the queue. Early: the program stamps the call before the port
  # stamps halting_since, and both round to a millisecond.
  POWER_HALTING_MS = 1000
  POWER_HALTING_EARLY_MS = 2
  POWER_HALTING_LATE_MS = 40
  POWER_IMMEDIATE_MAX_MS = 40
  POWER_HEARTBEAT_STOP_MS = 200
  # States and, for 8, 10 and 12, the order of the terminated link's or cancelled attempt's
  # disconnect (:disc_ff = handle 0xffff, :disc_33 = the link of the rig's answering peer).
  POWER_HALTING_REFERENCE = {
    8 => [3, :disc_ff, 0],
    9 => [1, 2],
    10 => [5, :disc_33, 4],
    11 => [1, 2],
    12 => [3, :disc_33, 0],
  }
  POWER_HALTING_NAMES = {
    8 => "power-off with a connect attempt nobody answers",
    9 => "power-on, link comes up",
    10 => "sleep with the link up, its disconnect arrives late",
    11 => "power-on from sleep",
    12 => "power-off with the link up",
  }
  # NimBLE calls that one hci_power_control makes, in order, with the power state at the
  # call (0 off, 1 on, 2 sleeping). OFF: power written first, then advertising stopped, the
  # held link terminated, the attempt cancelled, discovery stopped. SLEEP: the same without
  # the two stops. ON applies the kept scan wish (the program asked for a scan in step 1).
  POWER_NIMBLE_REFERENCE = {
    3 => [],
    4 => [["ble_gap_disc", 1]],
    5 => [["ble_gap_conn_active", 2]],
    6 => [["ble_gap_disc", 1]],
    7 => [],
    8 => [["ble_gap_adv_stop", 0], ["ble_gap_conn_active", 0], ["ble_gap_conn_cancel", 0], ["ble_gap_disc_cancel", 0]],
    9 => [["ble_gap_disc", 1]],
    10 => [["ble_gap_terminate", 2], ["ble_gap_conn_active", 2]],
    11 => [["ble_gap_disc", 1]],
    12 => [["ble_gap_adv_stop", 0], ["ble_gap_terminate", 0], ["ble_gap_conn_active", 0], ["ble_gap_disc_cancel", 0]],
  }
  POWER_NIMBLE_NAMES = {
    3 => "power-off while off", 4 => "power-on", 5 => "sleep", 6 => "power-on from sleep", 7 => "nested power-on",
    8 => "power-off, attempt pending", 9 => "power-on", 10 => "sleep, link up", 11 => "power-on from sleep",
    12 => "power-off, link up",
  }
  # First rig line of a run: everything before it is the idf.py build output
  # and the boot log, where a file name could contain "truncat".
  RIG_RUN_START = "write enq A"

  module_function

  def judge(log, max_latency_ms:, expect_fault: false, require_wlat: nil)
    total = log[INJECT_DONE, 1]
    received = {}
    log.scan(RECV) { |seq, tin, t| received[seq.to_i] ||= [tin.to_i, t.to_i] }

    problems = []
    problems << "no inject-done line in log" if total.nil?
    problems << "FOREIGN_PUSH detected (queue pushed off the VM thread)" if log.match?(FOREIGN_PUSH)
    problems << "write A never reached Ruby" unless log.match?(WRITE_A)
    problems << "write B never reached Ruby" unless log.match?(WRITE_B)
    problems << "fault hook did not fire" if expect_fault && !log.match?(FAULT)

    if total
      lost = (1..total.to_i).to_a - received.keys
      problems << "lost seq: #{lost.join(',')}" unless lost.empty?
    end

    late = received.filter_map do |seq, (tin, t)|
      latency = t - tin
      "seq=#{seq} #{latency}ms" if latency > max_latency_ms
    end
    problems << "latency > #{max_latency_ms}ms: #{late.join(', ')}" unless late.empty?

    wlat = log.scan(WLAT).map { |tin, t| t.to_i - tin.to_i }
    if require_wlat
      problems << "only #{wlat.size} wlat lines, expected #{require_wlat}" if wlat.size < require_wlat
      slow = wlat.select { |l| l > max_latency_ms }
      problems << "write latency > #{max_latency_ms}ms: #{slow.join(', ')}" unless slow.empty?
    end

    if problems.empty?
      worst = received.values.map { |tin, t| t - tin }.max
      Result.new(pass: true,
                 message: "#{received.size} events delivered, worst latency #{worst}ms <= #{max_latency_ms}ms, " \
                          "no foreign push, writes A and B delivered#{expect_fault ? ' after the injected fault' : ''}" \
                          "#{require_wlat ? ", write latency worst #{wlat.max}ms" : ''}")
    else
      Result.new(pass: false, message: problems.join("; "))
    end
  end

  def judge_flood(log, max_rejected: nil, min_rejected: nil)
    problems = []
    crash = log[FLOOD_CRASH]
    problems << "crash pattern matched: #{crash}" if crash
    done_match = FLOOD_DONE.match(log)
    problems << "no flood-done line with rejected count in log" if done_match.nil?
    received = nil
    bytes = nil
    if done_match
      problems << "no flood received= line in log" unless log.match?(FLOOD_RECV)
      sent = done_match[1].to_i
      rejected = done_match[2].to_i
      received, bytes = log.scan(FLOOD_RECV).last
      received = received.to_i
      problems << "accounting: received #{received} + rejected #{rejected} != sent #{sent}" if received + rejected != sent
      problems << "rejected #{rejected} > #{max_rejected}" if max_rejected && rejected > max_rejected
      problems << "rejected #{rejected} < #{min_rejected}: the bound never engaged" if min_rejected && rejected < min_rejected
    end

    if problems.empty?
      drops = log.scan(FLOOD_DROP).size
      Result.new(pass: true,
                 message: "flood received=#{received} bytes=#{bytes} rejected=#{rejected} sent=#{sent}, write-queue-full warnings=#{drops}")
    else
      Result.new(pass: false, message: problems.join("; "))
    end
  end

  # Per-handle write bound (PICORUBY_BLE_WRQ_PENDING): a refusal names the handle and
  # the count.
  HANDLE_REFUSED = /writes to handle (\d+) refused: (\d+) values not yet popped \(limit (\d+)\)/
  FLOOD_HANDLE = 0x43
  FLOOD_DONE_TIMES = /flood done n=\d+ rejected=\d+ begin=(\d+) end=(\d+) probes=(\d+)/
  FLOOD_RECV_TIMED = /flood received=(\d+) bytes=\d+ t=(\d+)/

  # Flood whose rejections must be explained: every rejection is the per-handle bound
  # (one log line naming the handle and the count), and with nothing rejected there is
  # no such line. judge_flood still does the crash and accounting checks.
  # The port logs from the injector task while Ruby prints on the same UART, which can
  # push a whole port line into the middle of a Ruby line. Put the Ruby line back together:
  # "[rigapp] wlat<port line>\n tin=1 t=2" becomes "<port line>\n[rigapp] wlat tin=1 t=2".
  def unsplit_port_logs(log)
    log.gsub(/^(\[rigapp\][^\n]*?)([WEI] \(\d+\) prb_ble_evq: [^\n]*\n)([^\n]*\n)/) { "#{$2}#{$1}#{$3}" }
  end

  def judge_flood_explained(log, max_rejected: nil)
    log = unsplit_port_logs(log)
    result = judge_flood(log, max_rejected: max_rejected)
    return result unless result.pass

    rejected = FLOOD_DONE.match(log)[2].to_i
    lines = log.scan(HANDLE_REFUSED)
    problems = []
    problems << "#{rejected} writes rejected and no per-handle 'writes to handle N refused' line in the log" if rejected.positive? && lines.empty?
    problems << "#{lines.size} per-handle lines in the log with nothing rejected" if rejected.zero? && !lines.empty?
    problems << "#{lines.size} per-handle lines, expected one per power session" if lines.size > 1
    verdict(problems, "#{result.message}, per-handle lines=#{lines.size}")
  end

  # Flood to a handle whose application pops only in the 1 Hz heartbeat
  # (EVQ_FLOOD_DRAIN=hb), judged against REVISION_3: the bound is PICORUBY_BLE_WRQ_PENDING
  # (limit) values per handle resident in Ruby.
  #   - no crash (NoMemoryError, Out of memory, abort, backtrace);
  #   - received + rejected == sent;
  #   - between two drains the handle takes exactly `limit` writes and refuses the rest,
  #     so every drain pops at most `limit` and the total received is a multiple of
  #     `limit`, at most limit * (h + 1): h drains fall inside the flood window
  #     [begin, end] (observed from the timed 'flood received' lines) and one more
  #     pops the batch that was resident at the end;
  #   - exactly one log line naming the flooded handle and the count `limit`;
  #   - the probe writes to a second handle, queued during the flood, all arrive within
  #     max_latency_ms (the saturated handle delays no other).
  def judge_flood_hb(log, limit: 16, max_latency_ms: 50)
    log = unsplit_port_logs(log)
    problems = []
    crash = log[FLOOD_CRASH] || log[/Backtrace:/]
    problems << "crash pattern matched: #{crash}" if crash
    done = FLOOD_DONE.match(log)
    timed = FLOOD_DONE_TIMES.match(log)
    problems << "no flood-done line with rejected count in log" if done.nil?
    problems << "no flood-done begin/end/probes in log" if timed.nil?
    if done.nil? || timed.nil?
      return Result.new(pass: false, message: problems.join("; "))
    end

    sent = done[1].to_i
    rejected = done[2].to_i
    begin_ms, end_ms, probes = timed.captures.map(&:to_i)
    drains = log.scan(FLOOD_RECV_TIMED).map { |count, t| [count.to_i, t.to_i] }
    received = drains.last ? drains.last[0] : 0
    batches = drains.each_with_index.map { |(count, _), i| count - (i.zero? ? 0 : drains[i - 1][0]) }
    inside = drains.count { |_, t| t >= begin_ms && t <= end_ms }
    problems << "no timed 'flood received' line in log" if drains.empty?
    problems << "accounting: received #{received} + rejected #{rejected} != sent #{sent}" if received + rejected != sent
    problems << "received #{received} is not a multiple of #{limit}" unless (received % limit).zero?
    problems << "a drain popped #{batches.max} values, more than the limit #{limit}" if batches.any? && batches.max > limit
    problems << "received #{received} exceeds #{limit} x (#{inside} drains inside the flood + 1) = #{limit * (inside + 1)}" if received > limit * (inside + 1)
    problems << "received nothing" if received.zero?

    lines = log.scan(HANDLE_REFUSED)
    named = lines.select { |h, c, l| h.to_i == FLOOD_HANDLE && c.to_i == limit && l.to_i == limit }
    problems << "#{lines.size} per-handle log lines, #{named.size} of them naming handle #{FLOOD_HANDLE} and count #{limit}; expected exactly one" unless lines.size == 1 && named.size == 1

    probe_latency = log.scan(WLAT).select { |tin, _t| tin.to_i >= begin_ms }.map { |tin, t| t.to_i - tin.to_i }
    problems << "#{probe_latency.size} of #{probes} writes to the second handle arrived" unless probe_latency.size == probes
    slow = probe_latency.select { |l| l > max_latency_ms }
    problems << "second-handle write latency > #{max_latency_ms}ms: #{slow.join(', ')}" unless slow.empty?

    summary = "flood received=#{received} rejected=#{rejected} sent=#{sent}; drains: #{batches.size} (#{inside} inside the flood window #{begin_ms}-#{end_ms}), " \
              "batches #{batches.inspect} => #{received} = #{limit} x #{received / limit} <= #{limit} x (#{inside} + 1); " \
              "per-handle log lines=#{lines.size}; second-handle writes #{probe_latency.size}/#{probes}, worst latency #{probe_latency.max.inspect}ms"
    verdict(problems, summary)
  end

  # Limits case (PICORUBY_QEMU_EVQ_LIMITS): an 80-event burst into the
  # 32-deep ring, then NOTIFY_RX values of 93 and 200 bytes.
  #   burst: when the ring is full the newest events must be refused
  #     (tail_only), never the oldest (a hole in the stream), and the
  #     firmware must say so (overflow_logged).
  #   notifications: each is delivered whole, or the firmware says it
  #     truncated (truncation_logged).
  # Nothing lost in the burst means the rig did not overflow the ring: a
  # failure of the rig, not a pass. Notifications pair with the injected
  # lengths by order of appearance.
  def judge_limits(log)
    fw = firmware_output(log)
    problems = []

    burst = BURST_DONE.match(log)
    problems << "no burst-done line in log" if burst.nil?
    received = []
    lost = []
    tail_only = nil
    if burst
      range = (burst[1].to_i..burst[2].to_i).to_a
      got = log.scan(RECV).map { |seq, _tin, _t| seq.to_i }
      received = range & got
      lost = range - received
      if received.empty?
        problems << "no burst event (#{range.first}-#{range.last}) reached Ruby: the rig or the consumer is broken"
      elsif lost.empty?
        problems << "the rig did not overflow the ring: all #{range.size} burst events reached Ruby"
      else
        tail_only = lost.min > received.max
      end
    end
    overflow_logged = fw.match?(RING_OVERFLOW_LOGGED)
    unless lost.empty? || received.empty?
      problems << "stream has a hole: lost seq #{seq_ranges(lost)} includes seq below the newest received #{received.max} (the oldest were dropped)" unless tail_only
      problems << "ring overflow lost #{lost.size} events but no 'event ring full' line in the log" unless overflow_logged
    end

    injected = log.scan(NOTIFY_INJECTED).flatten.map(&:to_i)
    seen = log.scan(NOTIF_SEEN).map { |len, _raw| len.to_i }
    problems << "no notify-injected line in log" if injected.empty?
    notifs = injected.each_with_index.map do |inj, i|
      { injected: inj, seen: seen[i], truncated: !seen[i].nil? && seen[i] < inj }
    end
    truncation_logged = fw.match?(TRUNCATION_LOGGED)
    missing = notifs.select { |n| n[:seen].nil? }
    cut = notifs.select { |n| n[:truncated] }
    problems << "notification of #{missing.map { |n| n[:injected] }.join(',')} bytes never reached Ruby" unless missing.empty?
    if !cut.empty? && !truncation_logged
      problems << "notification truncated (#{cut.map { |n| "#{n[:injected]}->#{n[:seen]}" }.join(', ')}) and no 'truncat' line in the log"
    end

    rig_ran = !burst.nil? && !received.empty? && !injected.empty?

    summary = "burst: received #{received.size}, lost #{lost.size}" \
              "#{lost.empty? ? '' : " (seq #{seq_ranges(lost)})"}, tail_only=#{tail_only.inspect}, overflow_logged=#{overflow_logged}; " \
              "notifications: " \
              "#{notifs.map { |n| "#{n[:injected]}->#{n[:seen].inspect}#{n[:truncated] ? ' truncated' : ''}" }.join(', ')}, " \
              "truncation_logged=#{truncation_logged}"
    if problems.empty?
      Result.new(pass: true, message: summary, rig_ran: rig_ran)
    else
      Result.new(pass: false, message: "#{summary}; FAIL: #{problems.join('; ')}", rig_ran: rig_ran)
    end
  end

  # Control event vs. data burst (L3): DISCONNECTION_COMPLETE h1, a burst
  # that overflows the ring, DISCONNECTION_COMPLETE h2, all back to back.
  # Ruby must see both, h1 first. Not run: no "control done" line,
  # no "mark 1", or no burst event at all reached Ruby. A burst that lost
  # nothing did not overflow the ring, which proves nothing: a failure.
  # The device logs the handle low byte only; the injected handles differ
  # in it.
  def judge_control_burst(log)
    fw = firmware_output(log)
    done = CONTROL_BURST_DONE.match(fw)
    return not_run("control: no 'control done' line in log") if done.nil?
    return not_run("control: the device program never logged 'mark 1' after the burst") unless fw.scan(MARK_SEEN).flatten.include?("1")

    range = (done[1].to_i..done[2].to_i).to_a
    got = fw.scan(RECV).map { |seq, _tin, _t| seq.to_i }
    received = range & got
    return not_run("control: no burst event (#{range.first}-#{range.last}) reached Ruby: the rig or the consumer is broken") if received.empty?

    problems = []
    problems << "the rig did not overflow the ring: all #{range.size} burst events reached Ruby" if received.size == range.size
    seen = fw.scan(DISC_SEEN).flatten.map(&:to_i)
    first, last = done[3].to_i, done[4].to_i
    first_seen = seen.include?(first & 0xff)
    last_seen = seen.include?(last & 0xff)
    problems << "DISCONNECTION_COMPLETE for handle 0x#{format('%04x', first)} (injected before the burst) never reached Ruby" unless first_seen
    problems << "DISCONNECTION_COMPLETE for handle 0x#{format('%04x', last)} (injected after the burst) never reached Ruby" unless last_seen
    if first_seen && last_seen && seen.index(first & 0xff) > seen.index(last & 0xff)
      problems << "DISCONNECTION_COMPLETE arrived out of order: 0x#{format('%04x', last)} before 0x#{format('%04x', first)}"
    end

    summary = "control: disconnect before burst seen=#{first_seen}, disconnect after burst seen=#{last_seen}, " \
              "burst received #{received.size} of #{range.size}"
    verdict(problems, summary)
  end

  # No CAN_SEND_NOW without a connection (L4): the injector calls
  # BLE_peripheral_request_can_send_now_event() n times while con_handle is
  # 0xffff; Ruby must receive none. Not run: no cansend-injected line,
  # con_handle was not 0xffff, or no "mark 2" after the wait.
  def judge_can_send_now(log)
    fw = firmware_output(log)
    injected = CANSEND_INJECTED.match(fw)
    return not_run("cansend: no 'cansend injected' line in log") if injected.nil?
    return not_run("cansend: con_handle was 0x#{format('%04x', injected[2].to_i)} when the rig called, not 0xffff: the rig has a connection") unless injected[2].to_i == CON_HANDLE_NONE
    return not_run("cansend: the device program never logged 'mark 2' after the calls") unless fw.scan(MARK_SEEN).flatten.include?("2")

    count = fw.scan(CANSEND_SEEN).size
    problems = []
    problems << "#{count} ATT_EVENT_CAN_SEND_NOW (0xB7) events reached Ruby with no connection, expected 0" unless count.zero?
    verdict(problems, "cansend: #{injected[1]} calls with con_handle=0xffff, #{count} CAN_SEND_NOW reached Ruby")
  end

  # Power-on reports INITIALIZING then WORKING (BTSTACK_EVENT_STATE 1, 2).
  # Only the STATE lines before the injector's own extra STATE(working)
  # count (the "extra state injected" line); those come from the port.
  # Not run: that line is missing or no STATE line precedes it.
  def judge_power_on_states(log)
    cut = log.index(EXTRA_STATE_INJECTED)
    return not_run("states: no 'extra state injected' line in log") if cut.nil?
    states = log[0...cut].scan(STATE_SEEN).flatten.map(&:to_i)
    return not_run("states: no STATE packet reached Ruby before the injector's own") if states.empty?

    problems = []
    problems << "power-on STATE sequence #{states.inspect} does not start with [1, 2] (INITIALIZING, WORKING)" unless states.first(2) == [1, 2]
    verdict(problems, "states: power-on sequence #{states.inspect}")
  end

  # The R1 checks of the limits run, for a port whose event ring is a byte ring
  # that refuses the newest entry (judge_limits_green). Each returns a Result.
  #
  # (a) The L1 burst: budget B bytes, entry E bytes (2 + packet), reserve 11 bytes
  #     that only a completion may use. With nothing drained, entries are accepted
  #     while used + E + 11 <= B, so floor((B - 11) / E) fit. The rig reports how
  #     many the ring accepted (A); A - floor(...) is what the pump moved out of the
  #     ring during the burst. Ruby must receive exactly the accepted events, in
  #     order, and nothing older than the first refusal may be missing.
  def judge_burst_refuses_newest(log)
    fw = firmware_output(log)
    burst = BURST_DONE.match(fw)
    acc = BURST_ACCEPTED.match(fw)
    return not_run("burst: no 'burst done' line in log") if burst.nil?
    return not_run("burst: no 'burst accepted' line in log (the port is not the byte-ring port)") if acc.nil?

    accepted, refused, first_refused, budget, entry = acc.captures.map(&:to_i)
    range = (burst[1].to_i..burst[2].to_i).to_a
    got = fw.scan(RECV).map { |seq, _tin, _t| seq.to_i } & range
    return not_run("burst: no burst event (#{range.first}-#{range.last}) reached Ruby: the rig or the consumer is broken") if got.empty?

    fits = (budget - EVQ_COMPLETION_RESERVE) / entry
    drained = accepted - fits
    problems = []
    problems << "the rig did not overflow the ring: all #{range.size} burst events were accepted" if refused.zero?
    problems << "the ring accepted #{accepted}, fewer than the #{fits} its budget holds" if accepted < fits
    problems << "Ruby received #{got.size} burst events, the ring accepted #{accepted}" unless got.size == accepted
    problems << "burst events reached Ruby out of order: #{got.first(8).join(',')}..." unless got == got.sort
    older = range.select { |s| first_refused.zero? || s < first_refused }
    missing_older = older - got
    problems << "seq #{seq_ranges(missing_older)} is older than the first refusal (seq #{first_refused}) and never reached Ruby" unless missing_older.empty?
    summary = "burst: budget #{budget} B, entry #{entry} B, reserve #{EVQ_COMPLETION_RESERVE} B => floor((#{budget}-#{EVQ_COMPLETION_RESERVE})/#{entry})=#{fits} fit with no drain; " \
              "ring accepted #{accepted} (#{drained} drained by the pump during the burst), refused #{refused} from seq #{first_refused}; " \
              "Ruby received #{got.size} (seq #{seq_ranges(got)})"
    verdict(problems, summary)
  end

  # (b) One "event ring full" line in the run, which is one power session.
  def judge_overflow_logged_once(log)
    fw = firmware_output(log)
    return not_run("overflow log: no 'burst done' line in log") unless fw.match?(BURST_DONE)

    count = fw.lines.count { |line| line.match?(RING_OVERFLOW_LOGGED) }
    problems = []
    problems << "#{count} 'event ring full' lines in the log, expected exactly 1 per power session" unless count == 1
    verdict(problems, "overflow log: #{count} 'event ring full' line(s) for the overflowing bursts of one power session")
  end

  # (c) Two descriptor-discovery procedures driven through the port's disc_dsc_cb:
  #     A (results fit) completes with status 0, B (results refused) with 0x11.
  def judge_completion_status(log)
    fw = firmware_output(log)
    procs = fw.scan(PROC_INJECTED).map { |name, n, first| [name, n.to_i, first.to_i] }
    return not_run("completion: no 'proc A/B injected' lines in log") unless procs.map(&:first) == %w[A B]
    return not_run("completion: the device program never logged 'mark 3' after the procedures") unless fw.scan(MARK_SEEN).flatten.include?("3")

    dsc = fw.scan(DSC_SEEN).flatten.map(&:to_i)
    completes = fw.scan(COMPLETE_SEEN).flatten.map(&:to_i)
    (_, a_n, a_first), (_, b_n, b_first) = procs
    a_got = dsc.count { |h| (a_first...(a_first + a_n)).cover?(h) }
    b_got = dsc.count { |h| (b_first...(b_first + b_n)).cover?(h) }
    problems = []
    problems << "#{completes.size} QUERY_COMPLETE events reached Ruby, expected 2 (one per procedure): #{completes.inspect}" unless completes.size == 2
    problems << "procedure A delivered #{a_got} of #{a_n} results" unless a_got == a_n
    problems << "procedure B delivered all #{b_n} results: the rig did not overflow the ring" if b_got == b_n
    if completes.size == 2
      problems << "completion of procedure A (nothing refused) has status #{completes[0]}, expected 0" unless completes[0].zero?
      unless completes[1] == STATUS_INSUFFICIENT_RESOURCES
        problems << "completion of procedure B (#{b_n - b_got} results refused) has status #{completes[1]}, expected 0x11"
      end
    end
    verdict(problems, "completion: A #{a_got}/#{a_n} results, status #{completes[0].inspect}; B #{b_got}/#{b_n} results, status #{completes[1].inspect}")
  end

  # (d) Notifications of 93 and 200 bytes arrive whole and the firmware logs no
  #     truncation.
  def judge_notifications_whole(log)
    fw = firmware_output(log)
    injected = fw.scan(NOTIFY_INJECTED).flatten.map(&:to_i)
    return not_run("notifications: no 'notify injected' line in log") if injected.empty?

    seen = fw.scan(NOTIF_SEEN).map { |len, _raw| len.to_i }
    problems = []
    problems << "notifications injected #{injected.inspect}, Ruby saw #{seen.inspect}" unless seen == injected
    problems << "a 'truncat' line is in the log" if fw.match?(TRUNCATION_LOGGED)
    verdict(problems, "notifications: injected #{injected.inspect}, Ruby saw #{seen.inspect}, truncation logged=#{fw.match?(TRUNCATION_LOGGED)}")
  end

  # (e) The DISCONNECTION_COMPLETE injected before the L3 burst reaches Ruby. The one
  #     injected after the burst is reported, not required: a ring that is full
  #     refuses it by design.
  def judge_disconnect_before_burst(log)
    fw = firmware_output(log)
    done = CONTROL_BURST_DONE.match(fw)
    return not_run("disconnect: no 'control done' line in log") if done.nil?
    return not_run("disconnect: the device program never logged 'mark 1' after the burst") unless fw.scan(MARK_SEEN).flatten.include?("1")

    seen = fw.scan(DISC_SEEN).flatten.map(&:to_i)
    first_seen = seen.include?(done[3].to_i & 0xff)
    last_seen = seen.include?(done[4].to_i & 0xff)
    problems = []
    problems << "DISCONNECTION_COMPLETE for handle 0x#{format('%04x', done[3].to_i)} (injected before the burst) never reached Ruby" unless first_seen
    verdict(problems, "disconnect: before the burst seen=#{first_seen}; after the burst (informational, refused when the ring is full) seen=#{last_seen}")
  end

  R1_CHECK_NAMES = {
    burst: "(a) burst: the oldest entries that fit the budget are delivered, in order",
    once: "(b) one 'event ring full' line per power session",
    completion: "(c) completion carries 0x11 when a result of its procedure was refused",
    notifications: "(d) notifications of 93 and 200 bytes arrive whole, no 'truncat' line",
    disconnect: "(e) the disconnect injected before the burst is delivered",
  }

  LATER_STEP_NAMES = {
    cansend: "no CAN_SEND_NOW without a connection",
    states: "power-on reports INITIALIZING then WORKING",
  }

  # [r1, later]: r1 are the checks of R1 (must pass on the byte-ring port), later
  # are the two checks of the limits run that belong to later steps; they are
  # expected to stay red until those steps land and never decide the verdict.
  def judge_limits_green(log)
    r1 = {
      R1_CHECK_NAMES[:burst] => judge_burst_refuses_newest(log),
      R1_CHECK_NAMES[:once] => judge_overflow_logged_once(log),
      R1_CHECK_NAMES[:completion] => judge_completion_status(log),
      R1_CHECK_NAMES[:notifications] => judge_notifications_whole(log),
      R1_CHECK_NAMES[:disconnect] => judge_disconnect_before_burst(log),
    }
    later = {
      LATER_STEP_NAMES[:cansend] => judge_can_send_now(log),
      LATER_STEP_NAMES[:states] => judge_power_on_states(log),
    }
    [r1, later]
  end

  def judge_limits_checks(log)
    {
      "limits (ring overflow, notification length)" => judge_limits(log),
      "control event survives a data burst" => judge_control_burst(log),
      "no CAN_SEND_NOW without a connection" => judge_can_send_now(log),
      "power-on reports INITIALIZING then WORKING" => judge_power_on_states(log),
    }
  end

  # Power case. Returns [steps, rig_ran, why]: steps is
  # [{n:, name:, expected:, got:, pass:}], rig_ran is false when the device
  # program did not finish the walk or the injector did not fire for step 7
  # (the steps then say nothing about the firmware); why names what is missing.
  def power_steps(log)
    fw = log[(log.index(POWER_BEGIN) || 0)..]
    injected = POWER_INJECTED.match(fw)
    handle_low = injected && (injected[1].to_i & 0xff)
    got = Hash.new { |h, k| h[k] = [] }
    fw.scan(POWER_STEP_EVENT) do |step, kind, value|
      if kind == "state"
        got[step.to_i] << value.to_i
      elsif value.to_i == handle_low
        got[step.to_i] << :disc
      end
    end
    steps = POWER_REFERENCE.map do |n, expected|
      actual = got[n]
      same = n == 7 ? actual.sort_by(&:to_s) == expected.sort_by(&:to_s) : actual == expected
      { n: n, name: POWER_STEP_NAMES[n], expected: expected, got: actual, pass: same }
    end
    why = []
    why << "no 'power begin' line in log" unless log.match?(POWER_BEGIN)
    why << "no 'power done' line in log (the walk did not finish)" unless log.match?(POWER_DONE)
    why << "no 'power inject disc' line in log (the injector did not fire for step 7)" if injected.nil?
    [steps, why.empty?, why.join("; ")]
  end

  def power_step_lines(steps)
    steps.map do |s|
      "step #{s[:n]}: #{s[:pass] ? 'PASS' : 'FAIL'} expected=[#{s[:expected].join(', ')}] got=[#{s[:got].join(', ')}] (#{s[:name]})"
    end
  end

  def judge_power(log)
    steps, rig_ran, why = power_steps(log)
    failed = steps.reject { |s| s[:pass] }.map { |s| s[:n] }
    summary = "power: #{steps.size - failed.size} of #{steps.size} steps match the reference"
    if !rig_ran
      Result.new(pass: false, message: "rig did not run: #{why}", rig_ran: false)
    elsif failed.empty?
      Result.new(pass: true, message: summary, rig_ran: true)
    else
      Result.new(pass: false, message: "#{summary}; FAIL: steps #{failed.join(',')}", rig_ran: true)
    end
  end

  # Power case against the port with a power state (esp32:evq_power_green). Returns
  # [checks, rig_ran, why]: checks is [{name:, pass:, detail:}]. The device program
  # (rigapp_power.rb) writes one "call" line before each hci_power_control, and the
  # NimBLE stubs (rig_nimble_stubs.c) write one line per call the port makes to the
  # host, so the lines between a "call" line and the next device-program line are the
  # calls that hci_power_control made, in order, with the power state at each.
  def power_green(log)
    walk = power_walk(log)
    checks = []
    steps, steps_ran, steps_why = power_steps(log)
    failed = steps.reject { |s| s[:pass] }.map { |s| s[:n] }
    checks << { name: "state events of steps 1-7", pass: failed.empty?,
                detail: failed.empty? ? "all seven match the reference" : "steps #{failed.join(',')} differ: #{power_step_lines(steps.reject { |s| s[:pass] }).join('; ')}" }

    POWER_HALTING_REFERENCE.each do |n, expected|
      got = (walk[:events][n] || []).map { |kind, value, _| power_event_name(kind, value) }
      checks << { name: "state events of step #{n} (#{POWER_HALTING_NAMES[n]})", pass: got == expected,
                  detail: "expected=[#{expected.join(', ')}] got=[#{got.join(', ')}]" }
    end

    POWER_NIMBLE_REFERENCE.each do |n, expected|
      call = walk[:calls][n]
      got = call ? call[:nimble].map { |c| [c[:name], c[:power]] } : nil
      ok = got == expected
      checks << { name: "NimBLE calls of step #{n} (#{POWER_NIMBLE_NAMES[n]})", pass: ok,
                  detail: "expected=[#{expected.map { |name, pw| "#{name}@#{pw}" }.join(', ')}] got=[#{(got || []).map { |name, pw| "#{name}@#{pw}" }.join(', ')}]#{got.nil? ? ' (no call line)' : ''}" }
    end

    [10, 12].each do |n|
      terminate = walk[:calls][n] && walk[:calls][n][:nimble].find { |c| c[:name] == "ble_gap_terminate" }
      ok = terminate && terminate[:handle] == POWER_LINK_HANDLE && terminate[:reason] == POWER_TERMINATE_REASON
      checks << { name: "terminate of step #{n} names the link and reason 0x13", pass: !!ok,
                  detail: terminate ? "handle=#{terminate[:handle]} reason=0x#{terminate[:reason].to_s(16)}" : "no ble_gap_terminate line" }
    end
    cancel = walk[:calls][8] && walk[:calls][8][:nimble].find { |c| c[:name] == "ble_gap_conn_active" }
    checks << { name: "step 8 finds the connect attempt pending", pass: !!(cancel && cancel[:ret] == 1),
                detail: cancel ? "ble_gap_conn_active -> #{cancel[:ret]}" : "no ble_gap_conn_active line" }

    [8, 10, 12].each do |n|
      call = walk[:calls][n]
      events = walk[:events][n] || []
      first = events.first
      disc = events.find { |kind, _, _| kind == "disc" }
      last = events.last
      if call && first && disc && last
        immediate = first[2] - call[:t]
        deadline = disc[2] - call[:t]
        together = last[2] - disc[2]
        ok = immediate <= POWER_IMMEDIATE_MAX_MS && deadline >= POWER_HALTING_MS - POWER_HALTING_EARLY_MS &&
             deadline <= POWER_HALTING_MS + POWER_HALTING_LATE_MS && together <= POWER_HALTING_LATE_MS
        checks << { name: "halting timer of step #{n}", pass: ok,
                    detail: "#{first[1]} after #{immediate} ms, the synthesised disconnect after #{deadline} ms (window #{POWER_HALTING_MS - POWER_HALTING_EARLY_MS}..#{POWER_HALTING_MS + POWER_HALTING_LATE_MS}), the final state #{together} ms after it" }
      else
        checks << { name: "halting timer of step #{n}", pass: false, detail: "missing call line or events" }
      end
    end

    on_beats = (walk[:hbs][4] || []).size
    checks << { name: "heartbeat runs while on (step 4)", pass: on_beats >= 1, detail: "#{on_beats} beat(s) in the 1500 ms window" }
    sleep_call = walk[:calls][5]
    late = sleep_call ? (walk[:hbs][5] || []).count { |t| t > sleep_call[:t] + POWER_HEARTBEAT_STOP_MS } : nil
    checks << { name: "heartbeat stops at sleep (step 5)", pass: late == 0,
                detail: late.nil? ? "no call line" : "#{late} beat(s) later than #{POWER_HEARTBEAT_STOP_MS} ms after the call" }

    step10_discs = (walk[:events][10] || []).count { |kind, _, _| kind == "disc" }
    dropped = firmware_output(log).match?(/dropped: handle=0x0033/)
    checks << { name: "the late disconnect of step 10 is dropped", pass: step10_discs == 1 && dropped,
                detail: "#{step10_discs} disconnect event(s) in step 10, port log line #{dropped ? 'present' : 'missing'}" }
    synthesised = firmware_output(log).match?(/halting deadline, synthesised one: handle=0xffff/)
    checks << { name: "the deadline logs the first synthesised disconnect", pass: firmware_output(log).match?(/halting deadline, synthesised one/),
                detail: synthesised ? "line present (handle 0xffff for the attempt)" : "line present for another handle, or missing" }

    problems = []
    problems << steps_why unless steps_ran
    problems << "#{walk[:calls].size} of #{POWER_CALL_STEPS.size} call lines in the log" unless walk[:calls].size == POWER_CALL_STEPS.size
    [checks, problems.empty?, problems.join("; ")]
  end

  def power_green_lines(checks)
    checks.map { |c| "#{c[:pass] ? 'PASS' : 'FAIL'}: #{c[:name]}: #{c[:detail]}" }
  end

  def power_event_name(kind, value)
    return value if kind == "state"
    { 255 => :disc_ff, POWER_LINK_HANDLE => :disc_33 }[value] || :"disc_#{value}"
  end

  def power_walk(log)
    fw = log[(log.index(POWER_BEGIN) || 0)..]
    calls = {}
    events = Hash.new { |h, k| h[k] = [] }
    hbs = Hash.new { |h, k| h[k] = [] }
    current = nil
    fw.each_line do |line|
      if (m = POWER_CALL.match(line))
        current = { step: m[1].to_i, kind: m[2], t: m[3].to_i, nimble: [] }
        calls[current[:step]] = current
      elsif (m = POWER_TIMED_EVENT.match(line))
        current = nil
        events[m[1].to_i] << [m[2], m[3].to_i, m[4].to_i]
      elsif (m = POWER_HB.match(line))
        current = nil
        hbs[m[1].to_i] << m[2].to_i
      elsif line.include?("[rigapp]")
        current = nil
      elsif current && (m = NIMBLE_CALL.match(line))
        current[:nimble] << { name: m[1], handle: m[2]&.to_i, reason: m[3]&.to_i(16), ret: m[4]&.to_i, power: m[5].to_i }
      end
    end
    { calls: calls, events: events, hbs: hbs }
  end

  def judge_power_green(log)
    checks, rig_ran, why = power_green(log)
    return not_run(why) unless rig_ran
    failed = checks.reject { |c| c[:pass] }
    summary = "power: #{checks.size - failed.size} of #{checks.size} checks hold"
    return Result.new(pass: true, message: summary, rig_ran: true) if failed.empty?
    Result.new(pass: false, message: "#{summary}; FAIL: #{failed.map { |c| c[:name] }.join('; ')}", rig_ran: true)
  end

  # Resync case. The device program starts a peripheral, advertises (control:
  # the host is synced, ble_gap_adv_start must get rc 0), waits out the rig
  # host's reset and re-sync, then starts a second peripheral and advertises at
  # once. Not run: a marker or the host's "resync done" line is missing, the
  # re-sync did not come before the second BLE.new, an advertise left no
  # ble_gap_adv_start line, or the control advertise failed (the rig's host is
  # then not behaving as a synced host, which proves nothing about the port).
  def judge_resync(log)
    control = log.index(RESYNC_CONTROL)
    second = log.index(RESYNC_SECOND_NEW)
    host_done = log.index(RESYNC_HOST_DONE)
    return not_run("resync: no 'resync control' line in log") if control.nil?
    return not_run("resync: no 'resync second new' line in log") if second.nil?
    return not_run("resync: the device program never logged 'resync done'") unless log.match?(RESYNC_DONE)
    return not_run("resync: no 'host resync done' line in log") if host_done.nil?
    return not_run("resync: the host's re-sync came after the second BLE.new") if host_done > second

    control_adv = log[control...second].scan(RESYNC_ADV_START).first
    second_adv = log[second..].scan(RESYNC_ADV_START).first
    return not_run("resync: no ble_gap_adv_start line for the control advertise") if control_adv.nil?
    return not_run("resync: no ble_gap_adv_start line for the advertise after the second BLE.new") if second_adv.nil?
    return not_run("resync: the control advertise got rc=#{control_adv[0]} with host_synced=#{control_adv[1]}") unless control_adv[0].to_i.zero?

    sync_cbs = log[0...second].scan(RESYNC_SYNC_CB).size
    rc, host_synced = second_adv.map(&:to_i)
    problems = []
    unless rc.zero?
      problems << "advertise after the second BLE.new reached ble_gap_adv_start with host_synced=#{host_synced} (rc=#{rc}" \
                  "#{rc == BLE_HS_ENOTSYNCED ? ' BLE_HS_ENOTSYNCED' : ''}): picoruby_nimble_start returned before the host was synced"
    end
    verdict(problems, "resync: control rc=0, sync_cb called #{sync_cbs} times before the second BLE.new, second advertise rc=#{rc} host_synced=#{host_synced}")
  end

  def not_run(message)
    Result.new(pass: false, message: "rig did not run: #{message}", rig_ran: false)
  end

  def verdict(problems, summary)
    if problems.empty?
      Result.new(pass: true, message: summary, rig_ran: true)
    else
      Result.new(pass: false, message: "#{summary}; FAIL: #{problems.join('; ')}", rig_ran: true)
    end
  end

  def firmware_output(log)
    start = log.index(RIG_RUN_START)
    start ? log[start..] : log
  end

  def seq_ranges(seqs)
    seqs.sort.slice_when { |a, b| b != a + 1 }.map { |r| r.size == 1 ? r.first.to_s : "#{r.first}-#{r.last}" }.join(",")
  end
end
