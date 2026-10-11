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
