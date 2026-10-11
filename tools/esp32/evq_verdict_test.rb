require_relative "evq_verdict"

log = <<~LOG
  [rigapp] write h=0x42 v="A"
  [rigapp] write h=0x42 v="B"
  [rigapp] recv seq=1 tin=1000 t=1004
  [rig] inject done n=1
LOG
r = EvqVerdict.judge(log, max_latency_ms: 50)
raise "expect pass, got: #{r.message}" unless r.pass

log2 = <<~LOG
  [rigapp] write h=0x42 v="B"
  [rigapp] recv seq=1 tin=1000 t=1900
  [rig] inject done n=1
LOG
raise "expect fail (latency)" if EvqVerdict.judge(log2, max_latency_ms: 50).pass

log3 = log + "[rig] FOREIGN_PUSH BLE_push_event\n"
raise "expect fail (foreign push)" if EvqVerdict.judge(log3, max_latency_ms: 50).pass

log4 = "[rigapp] write h=0x42 v=\"B\"\n[rig] inject done n=1\n"
raise "expect fail (lost)" if EvqVerdict.judge(log4, max_latency_ms: 50).pass

log5 = "[rigapp] write h=0x42 v=\"B\"\n[rigapp] recv seq=1 tin=1000 t=1004\n"
raise "expect fail (no inject-done line)" if EvqVerdict.judge(log5, max_latency_ms: 50).pass

clipped_prefix_log = <<~LOG
  write h=0x42 v="A"
  write h=0x42 v="B"
  recv seq=1 tin=1000 t=1004
  rig] inject done n=1
LOG
clipped_result = EvqVerdict.judge(clipped_prefix_log, max_latency_ms: 50)
raise "expect pass with clipped prefixes, got: #{clipped_result.message}" unless clipped_result.pass

flood_pass_log = <<~LOG
  [rigapp] flood received=50 bytes=6400
  [rig] flood done n=500 rejected=0
  [rigapp] flood received=500 bytes=64000
LOG
flood_pass = EvqVerdict.judge_flood(flood_pass_log)
raise "expect flood pass, got: #{flood_pass.message}" unless flood_pass.pass
raise "expect flood message to report counts" unless flood_pass.message.include?("received=500") && flood_pass.message.include?("bytes=64000")

flood_crash_log = <<~LOG
  [rigapp] flood received=50 bytes=6400
  Fatal error: Out of memory.
  Rebooting...
LOG
raise "expect flood fail (crash)" if EvqVerdict.judge_flood(flood_crash_log).pass

flood_no_done_log = "[rigapp] flood received=50 bytes=6400\n"
raise "expect flood fail (no flood-done line)" if EvqVerdict.judge_flood(flood_no_done_log).pass

flood_no_recv_after_log = <<~LOG
  [rigapp] flood received=50 bytes=6400
  [rig] flood done n=500
LOG
raise "expect flood fail (no received after done)" if EvqVerdict.judge_flood(flood_no_recv_after_log).pass

flood_drop_log = <<~LOG
  write queue full (depth=32), dropping; total dropped=3
  [rig] flood done n=500 rejected=0
  [rigapp] flood received=500 bytes=64000
LOG
flood_drop_result = EvqVerdict.judge_flood(flood_drop_log)
raise "expect flood pass with drops, got: #{flood_drop_result.message}" unless flood_drop_result.pass
raise "expect drop warnings reported" unless flood_drop_result.message.include?("write-queue-full warnings=1")

flood_clipped_log = <<~LOG
  rigapp] flood received=50 bytes=6400
  rig] flood done n=500 rejected=0
  rigapp] flood received=500 bytes=64000
LOG
flood_clipped_result = EvqVerdict.judge_flood(flood_clipped_log)
raise "expect flood pass with clipped prefixes, got: #{flood_clipped_result.message}" unless flood_clipped_result.pass

flood_acct_log = <<~LOG
  write queue full (depth=32), dropping; total dropped=1
  [rig] flood done n=500 rejected=452
  [rigapp] flood received=48 bytes=6144
LOG
r = EvqVerdict.judge_flood(flood_acct_log)
raise "expect flood pass (48 + 452 == 500), got: #{r.message}" unless r.pass
raise "expect rejected in message" unless r.message.include?("rejected=452")

flood_acct_bad_log = <<~LOG
  [rig] flood done n=500 rejected=10
  [rigapp] flood received=400 bytes=51200
LOG
raise "expect flood fail (400 + 10 != 500)" if EvqVerdict.judge_flood(flood_acct_bad_log).pass

flood_paced_log = <<~LOG
  [rig] flood done n=500 rejected=0
  [rigapp] flood received=500 bytes=64000
LOG
raise "expect paced pass" unless EvqVerdict.judge_flood(flood_paced_log, max_rejected: 0).pass
raise "expect paced fail when rejected > max" if EvqVerdict.judge_flood(flood_acct_log, max_rejected: 0).pass

raise "expect hb pass: 452 rejected satisfies min_rejected 1" unless EvqVerdict.judge_flood(flood_acct_log, min_rejected: 1).pass
raise "expect hb fail: nothing rejected means the bound never engaged" if EvqVerdict.judge_flood(flood_paced_log, min_rejected: 1).pass

oom_only_b_log = <<~LOG
  [rig] FAULT write
  [rigapp] write h=0x42 v="B"
  [rigapp] recv seq=1 tin=1000 t=1004
  [rig] inject done n=1
LOG
raise "expect fail: faulted write A never arrived" if EvqVerdict.judge(oom_only_b_log, max_latency_ms: 50, expect_fault: true).pass

oom_both_log = <<~LOG
  [rig] FAULT write
  [rigapp] write h=0x42 v="A"
  [rigapp] write h=0x42 v="B"
  [rigapp] recv seq=1 tin=1000 t=1004
  [rig] inject done n=1
LOG
raise "expect pass: A retried after the fault" unless EvqVerdict.judge(oom_both_log, max_latency_ms: 50, expect_fault: true).pass

wlat_log = oom_both_log + "[rigapp] wlat tin=5000 t=5012\n" * 20
raise "expect pass with 20 wlat lines" unless EvqVerdict.judge(wlat_log, max_latency_ms: 50, expect_fault: true, require_wlat: 20).pass
wlat_slow = oom_both_log + "[rigapp] wlat tin=5000 t=5012\n" * 19 + "[rigapp] wlat tin=6000 t=6900\n"
raise "expect fail: slow wlat" if EvqVerdict.judge(wlat_slow, max_latency_ms: 50, expect_fault: true, require_wlat: 20).pass
raise "expect fail: too few wlat" if EvqVerdict.judge(oom_both_log, max_latency_ms: 50, expect_fault: true, require_wlat: 20).pass

flood_early_last_log = <<~LOG
  [rigapp] flood received=450 bytes=57600
  [rigapp] flood received=500 bytes=64000
  [rig] flood done n=500 rejected=0
LOG
early = EvqVerdict.judge_flood(flood_early_last_log, max_rejected: 0)
raise "expect pass when the consumer finished before the done line, got: #{early.message}" unless early.pass

flood_short_log = <<~LOG
  [rigapp] flood received=450 bytes=57600
  [rig] flood done n=500 rejected=0
LOG
raise "expect fail: 450 + 0 != 500" if EvqVerdict.judge_flood(flood_short_log).pass

def limits_log(received:, overflow_line: nil, notifs: [[93, 92], [200, 92]], truncation_line: nil, prelude: "")
  lines = [prelude, "[rig] write enq A", "[rigapp] recv seq=7 tin=1000 t=1004"]
  received.each { |seq| lines << format("[rigapp] recv seq=%d tin=2000 t=2010", seq) }
  lines << overflow_line if overflow_line
  lines << "[rig] burst done first=101 last=180"
  notifs.each do |injected, seen|
    lines << truncation_line if truncation_line
    lines << "[rig] notify injected len=#{injected}"
    lines << "[rigapp] notif len=#{seen} raw=#{seen + 12}" if seen
  end
  lines << "[rig] limits done"
  lines.compact.join("\n") + "\n"
end

limits_red_log = limits_log(received: (149..180).to_a)
limits_red = EvqVerdict.judge_limits(limits_red_log)
raise "expect limits fail on the current firmware" if limits_red.pass
raise "expect hole reported, got: #{limits_red.message}" unless limits_red.message.include?("stream has a hole") && limits_red.message.include?("101-148")
raise "expect overflow_logged=false reported, got: #{limits_red.message}" unless limits_red.message.include?("overflow_logged=false") && limits_red.message.include?("no 'event ring full'")
raise "expect truncation reported, got: #{limits_red.message}" unless limits_red.message.include?("93->92 truncated") && limits_red.message.include?("200->92 truncated") && limits_red.message.include?("truncation_logged=false")
raise "expect tail_only=false and counts, got: #{limits_red.message}" unless limits_red.message.include?("received 32, lost 48") && limits_red.message.include?("tail_only=false")

limits_green_log = limits_log(received: (101..132).to_a,
                            overflow_line: "W (20123) prb_ble_evq: event ring full (depth=32), dropping newest; total dropped=48",
                            truncation_line: "W (22456) prb_ble_evq: notification value truncated to 92 bytes")
limits_green = EvqVerdict.judge_limits(limits_green_log)
raise "expect limits pass on the fixed firmware, got: #{limits_green.message}" unless limits_green.pass
raise "expect tail_only=true in the pass message, got: #{limits_green.message}" unless limits_green.message.include?("tail_only=true") && limits_green.message.include?("133-180") && limits_green.message.include?("overflow_logged=true")

limits_none_lost = EvqVerdict.judge_limits(limits_log(received: (101..180).to_a,
                                                    overflow_line: "W (1) prb_ble_evq: event ring full",
                                                    truncation_line: "W (2) prb_ble_evq: truncated"))
raise "expect limits fail when nothing was lost (rig failure)" if limits_none_lost.pass
raise "expect rig-did-not-overflow message, got: #{limits_none_lost.message}" unless limits_none_lost.message.include?("the rig did not overflow the ring: all 80")

limits_nothing_received = EvqVerdict.judge_limits(limits_log(received: [], overflow_line: "event ring full", truncation_line: "truncated"))
raise "expect limits fail when no burst event reached Ruby" if limits_nothing_received.pass

limits_hole_logged = EvqVerdict.judge_limits(limits_log(received: (149..180).to_a,
                                                      overflow_line: "W (1) prb_ble_evq: event ring full, dropping oldest",
                                                      truncation_line: "W (2) prb_ble_evq: truncated"))
raise "expect limits fail: logged but still dropped the oldest" if limits_hole_logged.pass

limits_overflow_unlogged = EvqVerdict.judge_limits(limits_log(received: (101..132).to_a, truncation_line: "W (2) prb_ble_evq: truncated"))
raise "expect limits fail: tail-only loss without an overflow line" if limits_overflow_unlogged.pass

limits_full_length = EvqVerdict.judge_limits(limits_log(received: (101..132).to_a,
                                                      overflow_line: "W (1) prb_ble_evq: Event Ring Full (depth=32)",
                                                      notifs: [[93, 93], [200, 200]]))
raise "expect limits pass: notifications delivered whole need no truncation line, got: #{limits_full_length.message}" unless limits_full_length.pass

limits_cut_unlogged = EvqVerdict.judge_limits(limits_log(received: (101..132).to_a, overflow_line: "W (1) prb_ble_evq: event ring full"))
raise "expect limits fail: truncated and not logged" if limits_cut_unlogged.pass

limits_missing_notif = EvqVerdict.judge_limits(limits_log(received: (101..132).to_a,
                                                        overflow_line: "W (1) prb_ble_evq: event ring full",
                                                        truncation_line: "W (2) prb_ble_evq: truncated",
                                                        notifs: [[93, 92], [200, nil]]))
raise "expect limits fail: a notification never reached Ruby" if limits_missing_notif.pass
raise "expect missing notification reported, got: #{limits_missing_notif.message}" unless limits_missing_notif.message.include?("200 bytes never reached Ruby")

limits_build_noise = EvqVerdict.judge_limits(limits_log(received: (149..180).to_a, prelude: "[1/9] Building C object truncation_helper.c.obj\nevent ring full in a build log"))
raise "expect limits fail: text before the rig run does not count as firmware output" if limits_build_noise.pass

raise "expect limits fail without a burst-done line" if EvqVerdict.judge_limits("[rigapp] recv seq=101 tin=1 t=2\n").pass

existing_log_limits = EvqVerdict.judge(oom_both_log, max_latency_ms: 50, expect_fault: true)
raise "expect the existing judge unchanged by limits lines" unless existing_log_limits.pass

raise "expect rig_ran on the current-firmware shape" unless limits_red.rig_ran == true
raise "expect rig_ran on the fixed-firmware shape" unless limits_green.rig_ran == true
raise "expect rig_ran when the firmware only fails" unless limits_hole_logged.rig_ran == true && limits_cut_unlogged.rig_ran == true
raise "expect rig_ran when nothing was lost (overflow miss is not a missing phase)" unless limits_none_lost.rig_ran == true
raise "expect rig_ran=false when no burst event reached Ruby" unless limits_nothing_received.rig_ran == false
no_burst_line = EvqVerdict.judge_limits("[rig] write enq A\n[rigapp] recv seq=101 tin=1 t=2\n[rig] notify injected len=93\n")
raise "expect rig_ran=false without a burst-done line" unless !no_burst_line.pass && no_burst_line.rig_ran == false
no_notify_line = EvqVerdict.judge_limits(limits_log(received: (101..132).to_a, overflow_line: "event ring full", notifs: []))
raise "expect rig_ran=false without a notify-injected line" unless !no_notify_line.pass && no_notify_line.rig_ran == false
crashed = EvqVerdict.judge_limits("Loading app.rb\nFATAL: NoMemoryError (NoMemoryError)\n")
raise "expect rig_ran=false when the device program died at load" unless !crashed.pass && crashed.rig_ran == false
raise "expect the other judges to leave rig_ran unset" unless EvqVerdict.judge(oom_both_log, max_latency_ms: 50, expect_fault: true).rig_ran.nil?

def checks_log(states: [1, 2], extra_state_line: true, control_done: true, burst: (230..260).to_a, disc: [34],
               mark1: true, cansend_line: "[rig] cansend injected n=5 con_handle=65535", cansend_seen: 0, mark2: true)
  lines = states.map { |st| "[rigapp] state #{st}" }
  lines << "[rig] extra state injected" if extra_state_line
  lines << "[rigapp] state 2" if extra_state_line
  lines << "[rig] write enq A"
  lines << "[rigapp] disc #{disc.first}" unless disc.empty?
  burst.each { |seq| lines << format("[rigapp] recv seq=%d tin=2000 t=2010", seq) }
  disc.drop(1).each { |lo| lines << "[rigapp] disc #{lo}" }
  lines << "[rig] control done first=201 last=260 h1=17 h2=34" if control_done
  lines << "[rigapp] mark 1" if mark1
  lines << cansend_line if cansend_line
  cansend_seen.times { lines << "[rigapp] cansend" }
  lines << "[rigapp] mark 2" if mark2
  lines << "[rig] limits done"
  lines.join("\n") + "\n"
end

control_green = EvqVerdict.judge_control_burst(checks_log(disc: [17, 34], burst: (201..231).to_a))
raise "expect control pass when both disconnects arrive, got: #{control_green.message}" unless control_green.pass && control_green.rig_ran == true
raise "expect control summary, got: #{control_green.message}" unless control_green.message.include?("disconnect before burst seen=true") && control_green.message.include?("burst received 31 of 60")

control_red = EvqVerdict.judge_control_burst(checks_log(disc: [34]))
raise "expect control fail on the current firmware" if control_red.pass
raise "expect control rig_ran on the current firmware" unless control_red.rig_ran == true
raise "expect the lost first disconnect reported, got: #{control_red.message}" unless control_red.message.include?("handle 0x0011 (injected before the burst) never reached Ruby") && control_red.message.include?("disconnect after burst seen=true")
raise "expect the second disconnect not reported lost, got: #{control_red.message}" if control_red.message.include?("handle 0x0022")

control_last_lost = EvqVerdict.judge_control_burst(checks_log(disc: [17]))
raise "expect control fail when the disconnect after the burst is refused, got: #{control_last_lost.message}" unless !control_last_lost.pass && control_last_lost.message.include?("handle 0x0022 (injected after the burst) never reached Ruby")

control_swapped = EvqVerdict.judge_control_burst(checks_log(disc: [34, 17], burst: (201..231).to_a))
raise "expect control fail when the disconnects arrive swapped" unless !control_swapped.pass && control_swapped.message.include?("out of order")

control_no_overflow = EvqVerdict.judge_control_burst(checks_log(disc: [17, 34], burst: (201..260).to_a))
raise "expect control fail (rig failure) when nothing was lost" unless !control_no_overflow.pass && control_no_overflow.rig_ran == true && control_no_overflow.message.include?("the rig did not overflow the ring: all 60")

control_no_done = EvqVerdict.judge_control_burst(checks_log(control_done: false))
raise "expect control not-run without the done line" unless !control_no_done.pass && control_no_done.rig_ran == false
control_no_mark = EvqVerdict.judge_control_burst(checks_log(mark1: false))
raise "expect control not-run without mark 1" unless !control_no_mark.pass && control_no_mark.rig_ran == false && control_no_mark.message.include?("mark 1")
control_no_burst = EvqVerdict.judge_control_burst(checks_log(burst: []))
raise "expect control not-run when no burst event reached Ruby" unless !control_no_burst.pass && control_no_burst.rig_ran == false
raise "expect control not-run on a log that died at load" unless EvqVerdict.judge_control_burst("FATAL: NoMemoryError (NoMemoryError)\n").rig_ran == false

cansend_green = EvqVerdict.judge_can_send_now(checks_log)
raise "expect cansend pass when none arrives, got: #{cansend_green.message}" unless cansend_green.pass && cansend_green.rig_ran == true
raise "expect cansend summary, got: #{cansend_green.message}" unless cansend_green.message.include?("5 calls with con_handle=0xffff, 0 CAN_SEND_NOW")

cansend_red = EvqVerdict.judge_can_send_now(checks_log(cansend_seen: 5))
raise "expect cansend fail on the current firmware" if cansend_red.pass
raise "expect cansend rig_ran on the current firmware" unless cansend_red.rig_ran == true
raise "expect cansend count reported, got: #{cansend_red.message}" unless cansend_red.message.include?("5 ATT_EVENT_CAN_SEND_NOW (0xB7) events reached Ruby with no connection, expected 0")

cansend_no_mark = EvqVerdict.judge_can_send_now(checks_log(mark2: false))
raise "expect cansend not-run without mark 2 (zero arrived is not proven)" unless !cansend_no_mark.pass && cansend_no_mark.rig_ran == false && cansend_no_mark.message.include?("mark 2")
cansend_no_line = EvqVerdict.judge_can_send_now(checks_log(cansend_line: nil))
raise "expect cansend not-run without the injected line" unless !cansend_no_line.pass && cansend_no_line.rig_ran == false
cansend_connected = EvqVerdict.judge_can_send_now(checks_log(cansend_line: "[rig] cansend injected n=5 con_handle=1"))
raise "expect cansend not-run when the rig had a connection" unless !cansend_connected.pass && cansend_connected.rig_ran == false && cansend_connected.message.include?("0x0001")

states_green = EvqVerdict.judge_power_on_states(checks_log(states: [1, 2]))
raise "expect states pass on 1, 2 before the injector's own, got: #{states_green.message}" unless states_green.pass && states_green.rig_ran == true
raise "expect states sequence reported, got: #{states_green.message}" unless states_green.message.include?("[1, 2]")

states_red = EvqVerdict.judge_power_on_states(checks_log(states: [2]))
raise "expect states fail on the current firmware (WORKING only; the injector's own 2 is not counted)" if states_red.pass
raise "expect states rig_ran on the current firmware" unless states_red.rig_ran == true
raise "expect states sequence reported, got: #{states_red.message}" unless states_red.message.include?("[2] does not start with [1, 2]")

states_reversed = EvqVerdict.judge_power_on_states(checks_log(states: [2, 1]))
raise "expect states fail when WORKING comes before INITIALIZING" if states_reversed.pass

states_no_cut = EvqVerdict.judge_power_on_states(checks_log(states: [1, 2], extra_state_line: false))
raise "expect states not-run without the extra-state line" unless !states_no_cut.pass && states_no_cut.rig_ran == false
states_none = EvqVerdict.judge_power_on_states(checks_log(states: []))
raise "expect states not-run when no STATE reached Ruby" unless !states_none.pass && states_none.rig_ran == false

named = EvqVerdict.judge_limits_checks(checks_log(states: [2], disc: [34], cansend_seen: 5))
raise "expect four named checks, got: #{named.keys.inspect}" unless named.keys.size == 4 && named.keys.uniq.size == 4
raise "expect every new check red on the current firmware shape" unless named.values.drop(1).none?(&:pass)
fixed = EvqVerdict.judge_limits_checks(checks_log(states: [1, 2], disc: [17, 34], burst: (201..231).to_a))
raise "expect the three new checks green on the fixed shape" unless fixed.values.drop(1).all?(&:pass)
limits_without_own_burst = EvqVerdict.judge_limits(checks_log)
raise "expect judge_limits not to take the control-burst line for its own" unless !limits_without_own_burst.pass && limits_without_own_burst.rig_ran == false

def power_log(steps, inject: true, begin_line: true, done_line: true)
  lines = []
  lines << "[rigapp] power begin" if begin_line
  lines << "[rig] power inject disc handle=51 call=4" if inject
  steps.each do |n, events|
    events.each do |e|
      lines << (e == :disc ? "[rigapp] step #{n} disc 51" : "[rigapp] step #{n} state #{e}")
    end
  end
  lines << "[rigapp] step 7 disc 17"
  lines << "[rigapp] power done" if done_line
  lines.join("\n") + "\n"
end

power_fixed = { 1 => [1, 2], 2 => [3, 0], 3 => [0], 4 => [1, 2], 5 => [5, 4], 6 => [1, 2], 7 => [:disc, 2] }
power_today = { 1 => [2], 4 => [2], 6 => [2], 7 => [2] }

green = EvqVerdict.judge_power(power_log(power_fixed))
raise "expect power pass on the reference sequence, got: #{green.message}" unless green.pass && green.rig_ran == true
power_steps, = EvqVerdict.power_steps(power_log(power_fixed))
raise "expect seven power steps" unless power_steps.size == 7 && power_steps.all? { |st| st[:pass] }
raise "expect a disc of another handle not to count for step 7" unless power_steps.last[:got] == [:disc, 2]

red = EvqVerdict.judge_power(power_log(power_today))
raise "expect power fail on today's shape" if red.pass
raise "expect power rig_ran on today's shape" unless red.rig_ran == true
raise "expect failing steps named, got: #{red.message}" unless red.message.include?("steps 1,2,3,4,5,6,7")
today_steps, = EvqVerdict.power_steps(power_log(power_today))
lines = EvqVerdict.power_step_lines(today_steps)
raise "expect step 1 line, got: #{lines[0]}" unless lines[0] == "step 1: FAIL expected=[1, 2] got=[2] (power-on)"
raise "expect step 3 line, got: #{lines[2]}" unless lines[2].start_with?("step 3: FAIL expected=[0] got=[]")
raise "expect step 7 line, got: #{lines[6]}" unless lines[6].include?("expected=[2, disc] got=[2]")

one_off = power_fixed.merge(5 => [4])
one_off_steps, = EvqVerdict.power_steps(power_log(one_off))
raise "expect only step 5 to fail" unless one_off_steps.reject { |st| st[:pass] }.map { |st| st[:n] } == [5]
lost_disc = power_fixed.merge(7 => [2])
raise "expect step 7 to fail when the injected event is lost" if EvqVerdict.judge_power(power_log(lost_disc)).pass
reordered = power_fixed.merge(7 => [2, :disc])
raise "expect step 7 to accept either order" unless EvqVerdict.judge_power(power_log(reordered)).pass

raise "expect power not-run without the inject line" unless EvqVerdict.judge_power(power_log(power_fixed, inject: false)).rig_ran == false
raise "expect power not-run without 'power done'" unless EvqVerdict.judge_power(power_log(power_fixed, done_line: false)).rig_ran == false
raise "expect power not-run without 'power begin'" unless EvqVerdict.judge_power(power_log(power_fixed, begin_line: false)).rig_ran == false
raise "expect power not-run on a log that died at load" unless EvqVerdict.judge_power("FATAL: NoMemoryError (NoMemoryError)\n").rig_ran == false

# Power case against the port with a power state (judge_power_green). The builder writes the
# log of a correct run from a spec per step; each test below changes one thing in the spec.
def green_spec
  nimble = lambda do |name, power, extra = ""|
    "[rig] nimble #{name}#{extra} power=#{power}"
  end
  {
    calls: {
      3 => ["off", []],
      4 => ["on", [nimble.("ble_gap_disc", 1)]],
      5 => ["sleep", [nimble.("ble_gap_conn_active", 2, " -> 0")]],
      6 => ["on", [nimble.("ble_gap_disc", 1)]],
      7 => ["on", []],
      8 => ["off", [nimble.("ble_gap_adv_stop", 0), nimble.("ble_gap_conn_active", 0, " -> 1"),
                    nimble.("ble_gap_conn_cancel", 0), nimble.("ble_gap_disc_cancel", 0)]],
      9 => ["on", [nimble.("ble_gap_disc", 1)]],
      10 => ["sleep", [nimble.("ble_gap_terminate", 2, " handle=51 reason=0x13"), nimble.("ble_gap_conn_active", 2, " -> 0")]],
      11 => ["on", [nimble.("ble_gap_disc", 1)]],
      12 => ["off", [nimble.("ble_gap_adv_stop", 0), nimble.("ble_gap_terminate", 0, " handle=51 reason=0x13"),
                     nimble.("ble_gap_conn_active", 0, " -> 0"), nimble.("ble_gap_disc_cancel", 0)]],
    },
    # [kind, value, ms after the call]
    events: {
      3 => [["state", 0, 5]],
      4 => [["state", 1, 8], ["state", 2, 10]],
      5 => [["state", 5, 5], ["state", 4, 6]],
      6 => [["state", 1, 8], ["state", 2, 10]],
      7 => [["state", 2, 6], ["disc", 51, 4]],
      8 => [["state", 3, 6], ["disc", 255, 1008], ["state", 0, 1008]],
      9 => [["state", 1, 8], ["state", 2, 10]],
      10 => [["state", 5, 6], ["disc", 51, 1008], ["state", 4, 1008]],
      11 => [["state", 1, 8], ["state", 2, 10]],
      12 => [["state", 3, 6], ["disc", 51, 1008], ["state", 0, 1008]],
      13 => [["state", 1, 8], ["state", 2, 10]],
      14 => [["state", 3, 6]],
      15 => [["state", 1, 8], ["state", 2, 10]],
      16 => [["state", 3, 6], ["disc", 51, 380], ["state", 0, 382]],
      17 => [["state", 1, 8], ["state", 2, 10]],
      18 => [["state", 3, 6]],
      19 => [["state", 3, 6], ["disc", 51, 800], ["state", 0, 802]],
      20 => [["state", 1, 8], ["state", 2, 10]],
      21 => [["state", 3, 6]],
      22 => [["state", 5, 6], ["disc", 51, 800], ["state", 4, 802]],
      23 => [["state", 1, 8], ["state", 2, 10]],
      24 => [["state", 5, 6]],
      25 => [["state", 3, 6], ["disc", 51, 1008], ["state", 0, 1010]],
      26 => [["state", 1, 8], ["state", 2, 10]],
      27 => [["state", 5, 6]],
      28 => [["state", 5, 6], ["disc", 51, 800], ["state", 4, 802]],
      29 => [["state", 1, 8], ["state", 2, 10]],
      30 => [["state", 2, 6]],
      31 => [["state", 3, 6], ["disc", 51, 1008], ["state", 0, 1010]],
      32 => [["state", 1, 8], ["state", 2, 10]],
      33 => [["state", 3, 6], ["state", 0, 8]],
    },
    hbs: { 4 => [1000], 5 => [4], 29 => [1000], 31 => [4] },
    # port log lines, by the step whose output they follow
    after: {
      8 => ["W (9541) prb_ble_evq: no disconnect arrived within the halting deadline, synthesised one: handle=0xffff",
            "W (9998) prb_ble_evq: this power session: stale events dropped=0 halting discards=1 adv re-armed=0"],
      10 => ["W (9999) prb_ble_evq: dropped a disconnect that belongs to an earlier power session: handle=0x0033"],
      12 => ["W (9998) prb_ble_evq: this power session: stale events dropped=1 halting discards=1 adv re-armed=0"],
      33 => ["[rig] host CONNECT handle=51", "[rig] nimble ble_gap_terminate handle=51 reason=0x13 -> 0 power=0",
             "W (9999) prb_ble_evq: dropped a disconnect that belongs to an earlier power session: handle=0x0033"],
    },
  }
end

SPEC_KINDS = { 13 => "on", 14 => "off", 15 => "on", 16 => "off", 17 => "on", 18 => "off", 19 => "off", 20 => "on", 21 => "off", 22 => "sleep",
               23 => "on", 24 => "sleep", 25 => "off", 26 => "on", 27 => "sleep", 28 => "sleep", 29 => "on", 30 => "on", 31 => "off",
               32 => "on", 33 => "off" }

def green_log(spec = green_spec, begin_line: true, done_line: true)
  lines = []
  lines << "[rigapp] power begin" if begin_line
  lines << "[rig] power inject disc handle=51 call=4"
  lines << "[rigapp] step 1 state 1 t=100" << "[rigapp] step 1 state 2 t=101"
  lines << "[rigapp] step 2 state 3 t=800" << "[rigapp] step 2 state 0 t=801"
  t = 1000
  (3..33).each do |n|
    kind, nimble = spec[:calls][n] || [SPEC_KINDS[n] || "off", []]
    lines << "[rigapp] step #{n} call #{kind} t=#{t}"
    lines.concat(nimble)
    spec[:events][n].each { |k, v, dt| lines << "[rigapp] step #{n} #{k} #{v} t=#{t + dt}" }
    (spec[:hbs][n] || []).each { |dt| lines << "[rigapp] step #{n} hb t=#{t + dt}" }
    lines.concat(spec[:after][n] || [])
    t += 3000
  end
  lines << "[rigapp] power done" if done_line
  lines.join("\n") + "\n"
end

def green_check(log, name_part)
  checks, = EvqVerdict.power_green(log)
  checks.find { |c| c[:name].include?(name_part) } or raise "no check named #{name_part}: #{checks.map { |c| c[:name] }.inspect}"
end

ok = EvqVerdict.judge_power_green(green_log)
raise "expect power_green pass on a correct run, got: #{ok.message}" unless ok.pass && ok.rig_ran == true
checks, = EvqVerdict.power_green(green_log)
raise "expect every check to pass on a correct run: #{EvqVerdict.power_green_lines(checks.reject { |c| c[:pass] })}" unless checks.all? { |c| c[:pass] }
raise "expect 53 checks, got #{checks.size}" unless checks.size == 53

# the expected state events: a missing STATE(3) is caught in step 8
spec = green_spec
spec[:events][8] = [["disc", 255, 1008], ["state", 0, 1008]]
raise "expect a missing HALTING to fail step 8" if green_check(green_log(spec), "state events of step 8")[:pass]

# the synthesised disconnect must come before the final state
spec = green_spec
spec[:events][12] = [["state", 3, 6], ["state", 0, 1008], ["disc", 51, 1008]]
raise "expect disconnect-after-OFF to fail step 12" if green_check(green_log(spec), "state events of step 12")[:pass]

# the order of the NimBLE calls at OFF: terminate before the advertising stop
spec = green_spec
spec[:calls][12] = ["off", spec[:calls][12][1].values_at(1, 0, 2, 3)]
raise "expect terminate-before-adv_stop to fail the call order of step 12" if green_check(green_log(spec), "NimBLE calls of step 12")[:pass]

# power must already be OFF at the first stopping call
spec = green_spec
spec[:calls][8] = ["off", spec[:calls][8][1].map { |l| l.sub("power=0", "power=1") }]
raise "expect a call made with power still on to fail step 8" if green_check(green_log(spec), "NimBLE calls of step 8")[:pass]

# SLEEP leaves advertising and discovery running: an adv_stop in it is a failure
spec = green_spec
spec[:calls][10] = ["sleep", ["[rig] nimble ble_gap_adv_stop power=2"] + spec[:calls][10][1]]
raise "expect adv_stop at sleep to fail step 10" if green_check(green_log(spec), "NimBLE calls of step 10")[:pass]

# the terminate must name the link and reason 0x13
spec = green_spec
spec[:calls][12] = ["off", spec[:calls][12][1].map { |l| l.sub("reason=0x13", "reason=0x16") }]
raise "expect reason 0x16 to fail the terminate check" if green_check(green_log(spec), "terminate of step 12")[:pass]

# the halting timer: early, late and on time
[[900, false], [1000, true], [1038, true], [1100, false]].each do |dt, expect|
  spec = green_spec
  spec[:events][8] = [["state", 3, 6], ["disc", 255, dt], ["state", 0, dt]]
  got = green_check(green_log(spec), "halting timer of step 8")[:pass]
  raise "expect halting timer at #{dt} ms to be #{expect}" unless got == expect
end
spec = green_spec
spec[:events][10] = [["state", 5, 6], ["disc", 51, 1008], ["state", 4, 1100]]
raise "expect a final state long after the disconnect to fail" if green_check(green_log(spec), "halting timer of step 10")[:pass]
spec = green_spec
spec[:events][12] = [["state", 3, 300], ["disc", 51, 1008], ["state", 0, 1008]]
raise "expect a HALTING that is not immediate to fail" if green_check(green_log(spec), "halting timer of step 12")[:pass]

# heartbeat: running while on, stopped at sleep
spec = green_spec
spec[:hbs] = { 4 => [], 5 => [4] }
raise "expect no beat while on to fail" if green_check(green_log(spec), "heartbeat runs")[:pass]
spec = green_spec
spec[:hbs] = { 4 => [1000], 5 => [4, 900] }
raise "expect a beat after sleep to fail" if green_check(green_log(spec), "heartbeat stops")[:pass]

# the late disconnect: dropped silently and logged, never a second event
spec = green_spec
spec[:events][10] = [["state", 5, 6], ["disc", 51, 1008], ["state", 4, 1008], ["disc", 51, 1300]]
raise "expect a second disconnect to fail the late-disconnect check" if green_check(green_log(spec), "late disconnect")[:pass]
spec = green_spec
spec[:after][10] = []
raise "expect a missing drop line to fail" if green_check(green_log(spec), "late disconnect")[:pass]
spec = green_spec
spec[:after][8] = spec[:after][8].drop(1)
raise "expect a missing deadline line to fail" if green_check(green_log(spec), "deadline logs")[:pass]

# a power-off, power-on, power-off with one link held: the earlier session's disconnect must not
# reach Ruby after the state OFF (the old port forgot the link on BLE_HS_EALREADY)
spec = green_spec
spec[:events][16] = [["state", 3, 6], ["state", 0, 8], ["disc", 51, 380]]
raise "expect a disconnect after STATE(0) to fail step 16" if green_check(green_log(spec), "state events of step 16")[:pass]
spec = green_spec
spec[:events][16] = [["state", 3, 6], ["disc", 51, 1008], ["state", 0, 1010]]
raise "expect a deadline-synthesised disconnect to fail the step 16 timing check" if green_check(green_log(spec), "step 16 delivers")[:pass]

# a power transition during a pending halt: one STATE per halt
spec = green_spec
spec[:events][19] = [["state", 0, 6], ["disc", 51, 800], ["state", 0, 802]]
raise "expect OFF during a pending OFF to fail when it announces OFF at once" if green_check(green_log(spec), "state events of step 19")[:pass]
spec = green_spec
spec[:events][22] = [["state", 0, 6], ["disc", 51, 800], ["state", 0, 802]]
raise "expect SLEEP during a pending OFF to fail when the halt still ends in OFF" if green_check(green_log(spec), "state events of step 22")[:pass]
spec = green_spec
spec[:events][28] = [["state", 4, 6], ["disc", 51, 800], ["state", 4, 802]]
raise "expect SLEEP during a pending SLEEP to fail when it announces SLEEPING at once" if green_check(green_log(spec), "state events of step 28")[:pass]
spec = green_spec
spec[:events][25] = [["state", 3, 6], ["disc", 51, 1008], ["state", 0, 1010], ["state", 0, 1100]]
raise "expect a second STATE(0) for one halt to fail" if green_check(green_log(spec), "state events of step 25")[:pass]

# the heartbeat follows the last call: a nested power-on does not keep it alive past a power-off
spec = green_spec
spec[:hbs][31] = [4, 1004]
raise "expect a beat after power-off to fail" if green_check(green_log(spec), "no heartbeat after a power-off")[:pass]
spec = green_spec
spec[:hbs][29] = []
raise "expect no beat while on (step 29) to fail" if green_check(green_log(spec), "heartbeat runs while on (step 29)")[:pass]

# the summary of a power-off counts the deadline discard of that power-off
spec = green_spec
spec[:after][8] = spec[:after][8].take(1)
raise "expect a missing summary to fail step 8" if green_check(green_log(spec), "summary of step 8")[:pass]
spec = green_spec
spec[:after][8] = [spec[:after][8][0]]
spec[:after][9] = [green_spec[:after][8][1]]
raise "expect a summary that comes after the next power-on to fail" if green_check(green_log(spec), "summary of step 8")[:pass]

# a link accepted after the halt completed: terminated at once, its disconnect dropped, none delivered
spec = green_spec
spec[:events][33] = [["state", 3, 6], ["state", 0, 8], ["disc", 51, 300]]
raise "expect a delivered disconnect to fail step 33" if green_check(green_log(spec), "link accepted after the halt")[:pass]
spec = green_spec
spec[:after][33] = spec[:after][33].reject { |l| l.include?("dropped") }
raise "expect a missing drop line to fail step 33" if green_check(green_log(spec), "link accepted after the halt")[:pass]
spec = green_spec
spec[:after][33] = spec[:after][33].map { |l| l.sub("power=0", "power=1") }
raise "expect a terminate made with power on to fail step 33" if green_check(green_log(spec), "link accepted after the halt")[:pass]
spec = green_spec
spec[:events][33] = [["state", 3, 6], ["state", 0, 600]]
raise "expect a halt that is not immediate to fail step 33" if green_check(green_log(spec), "link accepted after the halt")[:pass]

# not run: no 'power done', no 'power begin', a call line missing, a log that died at load
raise "expect not-run without 'power done'" unless EvqVerdict.judge_power_green(green_log(done_line: false)).rig_ran == false
raise "expect not-run without 'power begin'" unless EvqVerdict.judge_power_green(green_log(begin_line: false)).rig_ran == false
dropped_call = green_log.lines.reject { |l| l.include?("step 9 call") }.join
raise "expect not-run with a call line missing" unless EvqVerdict.judge_power_green(dropped_call).rig_ran == false
raise "expect not-run on a log that died at load" unless EvqVerdict.judge_power_green("FATAL: NoMemoryError (NoMemoryError)\n").rig_ran == false

# the old port: today's shape fails the green judge and runs the rig
today = green_spec
today[:events] = today[:events].transform_values { |_| [] }
today[:events][4] = [["state", 2, 8]]
today[:events][7] = [["state", 2, 6]]
today_result = EvqVerdict.judge_power_green(green_log(today))
raise "expect today's shape to fail the green judge, got: #{today_result.message}" if today_result.pass
raise "expect today's shape to run the rig" unless today_result.rig_ran == true

def resync_log(second_rc: 0, second_synced: 1, control_rc: 0, host_done: true, order_ok: true, done: true, second_adv: true)
  lines = ["[rig] host sync_cb session=1", "[rigapp] resync control",
           "[rig] ble_gap_adv_start rc=#{control_rc} host_synced=#{control_rc.zero? ? 1 : 0}"]
  host = ["[rig] host reset_cb session=1", "[rig] host sync_cb session=1", "[rig] host resync done"]
  lines += host if host_done && order_ok
  lines << "[rigapp] resync second new"
  lines += host if host_done && !order_ok
  lines << "[rig] ble_gap_adv_start rc=#{second_rc} host_synced=#{second_synced}" if second_adv
  lines << "[rigapp] resync done" if done
  lines.join("\n") + "\n"
end

resync_green = EvqVerdict.judge_resync(resync_log)
raise "expect resync pass, got: #{resync_green.message}" unless resync_green.pass && resync_green.rig_ran == true
resync_red = EvqVerdict.judge_resync(resync_log(second_rc: 22, second_synced: 0))
raise "expect resync fail on a premature start" if resync_red.pass
raise "expect resync rig_ran on a premature start" unless resync_red.rig_ran == true
raise "expect rc named, got: #{resync_red.message}" unless resync_red.message.include?("host_synced=0 (rc=22 BLE_HS_ENOTSYNCED)")
raise "expect resync not-run when the control fails" unless EvqVerdict.judge_resync(resync_log(control_rc: 22)).rig_ran == false
raise "expect resync not-run without the host's re-sync" unless EvqVerdict.judge_resync(resync_log(host_done: false)).rig_ran == false
raise "expect resync not-run when the re-sync came late" unless EvqVerdict.judge_resync(resync_log(order_ok: false)).rig_ran == false
raise "expect resync not-run without 'resync done'" unless EvqVerdict.judge_resync(resync_log(done: false)).rig_ran == false
raise "expect resync not-run without the second adv line" unless EvqVerdict.judge_resync(resync_log(second_adv: false)).rig_ran == false
raise "expect resync not-run on a log that died at load" unless EvqVerdict.judge_resync("FATAL: NoMemoryError (NoMemoryError)\n").rig_ran == false

# Limits run against the byte-ring port (judge_limits_green). The burst numbers are
# the rig's: budget 1024, entry 32 (2 + 30), reserve 11 => floor(1013 / 32) = 31 fit.
def green_log(accepted: 31, first_refused: 132, received: nil, burst_order: nil, overflow_lines: 1,
              notifs: [93, 200], seen: nil, truncat: false, proc_a_results: 3, proc_b_results: 20,
              status_a: 0, status_b: 0x11, disc_before: true, disc_after: false, mark3: true, budget: 1024, entry: 32,
              cansend: 0, states: [2])
  received ||= (101...(101 + accepted)).to_a
  received = burst_order if burst_order
  lines = ["write enq A"]
  lines << "[rig] burst accepted=#{accepted} refused=#{80 - accepted} first_refused=#{first_refused} budget=#{budget} entry=#{entry}"
  lines << "[rig] burst done first=101 last=180"
  received.each { |s| lines << "[rigapp] recv seq=#{s} tin=1000 t=1005" }
  overflow_lines.times { lines << "W (1234) prb_ble_evq: event ring full (budget=#{budget} bytes), refusing the newest entries until Ruby drains it" }
  seen ||= notifs
  notifs.each_with_index { |n, i| lines << "[rig] notify injected len=#{n}"; lines << "[rigapp] notif len=#{seen[i]} raw=#{seen[i] + 12}" if seen[i] }
  lines << "E (2000) prb_ble_evq: notification value truncated: 300 bytes, event carries 255" if truncat
  lines << "[rig] control done first=201 last=260 h1=17 h2=34"
  lines << "[rigapp] disc 17" if disc_before
  lines << "[rigapp] disc 34" if disc_after
  lines << "[rigapp] mark 1"
  lines << "[rig] cansend injected n=5 con_handle=65535"
  cansend.times { lines << "[rigapp] cansend" }
  lines << "[rigapp] mark 2"
  lines << "[rig] proc A injected results=3 handle_first=1"
  proc_a_results.times { |i| lines << "[rigapp] dsc #{1 + i}" }
  lines << "[rig] proc A done" << "[rigapp] complete #{status_a}"
  lines << "[rig] proc B injected results=100 handle_first=101"
  proc_b_results.times { |i| lines << "[rigapp] dsc #{101 + i}" }
  lines << "[rig] proc B done" << "[rigapp] complete #{status_b}"
  lines << "[rigapp] mark 3" if mark3
  lines << "[rig] limits done"
  lines.insert(1, *states.map { |s| "[rigapp] state #{s}" }, "[rig] extra state injected") # port states, then the injector's own
  lines.join("\n") + "\n"
end

def green_checks(log)
  r1, later = EvqVerdict.judge_limits_green(log)
  [r1.transform_keys { |k| k[/\A\(\w\)/] }, later]
end

r1, later = green_checks(green_log)
raise "expect five R1 checks, got #{r1.keys}" unless r1.keys == %w[(a) (b) (c) (d) (e)]
raise "expect every R1 check green, got: #{r1.reject { |_, r| r.pass }.map { |k, r| "#{k} #{r.message}" }}" unless r1.values.all?(&:pass)
raise "expect the derivation in (a): #{r1['(a)'].message}" unless r1["(a)"].message.include?("floor((1024-11)/32)=31 fit") && r1["(a)"].message.include?("0 drained")
raise "expect the two later-step checks by name" unless later.keys == ["no CAN_SEND_NOW without a connection", "power-on reports INITIALIZING then WORKING"]
raise "expect the power-on states check red with [2]" if later.values.last.pass

# (a): pump drained 5 entries during the burst => 36 accepted, first refused later, all delivered
r1, = green_checks(green_log(accepted: 36, first_refused: 137))
raise "expect (a) green with drained entries, got: #{r1['(a)'].message}" unless r1["(a)"].pass && r1["(a)"].message.include?("5 drained")
# (a): accepted fewer than the budget holds
raise "expect (a) fail: ring accepted 20 < 31" if green_checks(green_log(accepted: 20, first_refused: 121))[0]["(a)"].pass
# (a): Ruby received fewer than accepted (an accepted entry lost)
lost = green_log(accepted: 31, first_refused: 132, received: (101..130).to_a)
raise "expect (a) fail: 30 delivered of 31 accepted" if green_checks(lost)[0]["(a)"].pass
# (a): the oldest dropped (what the old ring did): newest 31 delivered
oldest_dropped = green_log(accepted: 31, first_refused: 132, received: (150..180).to_a)
raise "expect (a) fail: oldest entries dropped" if green_checks(oldest_dropped)[0]["(a)"].pass
# (a): out of order
swapped = green_log(accepted: 31, first_refused: 132, burst_order: (101..131).to_a.reverse)
raise "expect (a) fail: out of order" if green_checks(swapped)[0]["(a)"].pass
# (a): the rig did not overflow
no_overflow = green_log(accepted: 80, first_refused: 0)
no_overflow_result = green_checks(no_overflow)[0]["(a)"]
raise "expect (a) fail: no overflow" if no_overflow_result.pass
# (a): not run on the old port (no 'burst accepted' line)
old_port = green_log.sub(/^\[rig\] burst accepted.*\n/, "")
raise "expect (a) not-run on the old port" unless green_checks(old_port)[0]["(a)"].rig_ran == false
# (b)
raise "expect (b) fail: logged twice" if green_checks(green_log(overflow_lines: 2))[0]["(b)"].pass
raise "expect (b) fail: not logged" if green_checks(green_log(overflow_lines: 0))[0]["(b)"].pass
# (c)
raise "expect (c) fail: B completes with 0 over refused results (old port)" if green_checks(green_log(status_b: 0))[0]["(c)"].pass
raise "expect (c) fail: A completes with 0x11" if green_checks(green_log(status_a: 0x11))[0]["(c)"].pass
raise "expect (c) fail: B delivered all 100 results" if green_checks(green_log(proc_b_results: 100))[0]["(c)"].pass
raise "expect (c) fail: A lost a result" if green_checks(green_log(proc_a_results: 2))[0]["(c)"].pass
raise "expect (c) not-run without mark 3" unless green_checks(green_log(mark3: false))[0]["(c)"].rig_ran == false
# (d)
raise "expect (d) fail: 93 arrived as 92" if green_checks(green_log(seen: [92, 200]))[0]["(d)"].pass
raise "expect (d) fail: truncation line" if green_checks(green_log(truncat: true))[0]["(d)"].pass
raise "expect (d) not-run without notify lines" unless green_checks(green_log(notifs: []))[0]["(d)"].rig_ran == false
# the 'truncat' check ignores the build output before the run's first rig line
build_noise = "CC src/truncation.c\n" + green_log
raise "expect (d) green with a 'truncat' file name in the build output" unless green_checks(build_noise)[0]["(d)"].pass
# (e)
raise "expect (e) fail: first disconnect lost" if green_checks(green_log(disc_before: false))[0]["(e)"].pass
r1, = green_checks(green_log(disc_after: true))
raise "expect (e) green and reporting the second disconnect" unless r1["(e)"].pass && r1["(e)"].message.include?("seen=true")
# later steps never decide: a log where both turn green still has the R1 checks green
r1, later = green_checks(green_log(states: [1, 2]))
raise "expect later power-on check green with [1, 2]" unless later.values.last.pass
raise "expect R1 checks unaffected by the later-step checks" unless r1.values.all?(&:pass)
r1, later = green_checks(green_log(cansend: 5))
raise "expect later CAN_SEND_NOW check red with 5 events" if later.values.first.pass

# Flood to a handle drained only on the heartbeat (judge_flood_hb) and the explained-rejection
# judge of the continuous floods, against the per-handle bound of 16 (REVISION_3).
def hb_log(drain_times: [1400, 2400], drains: nil, rejected: 436, begin_ms: 1000, end_ms: 2000, probes: 50,
           probe_latencies: nil, refused_lines: ["W (1500) prb_ble_evq: handle 67 holds 16 values Ruby has not popped; refusing newer writes to it until Ruby pops"],
           crash: nil, sent: 500)
  drains ||= drain_times.each_with_index.map { |t, i| [16 * (i + 1), t] }
  lines = ["[rig] wlat done n=20"]
  lines.concat(refused_lines)
  (probe_latencies || Array.new(probes, 12)).each_with_index { |l, i| lines << "[rigapp] wlat tin=#{1000 + i * 20} t=#{1000 + i * 20 + l}" }
  lines << "[rigapp] wlat tin=500 t=700" # before the flood: not a probe
  drains.each { |count, t| lines << "[rigapp] flood received=#{count} bytes=#{count * 128} t=#{t}" }
  lines << crash if crash
  lines << "[rig] flood done n=#{sent} rejected=#{rejected} begin=#{begin_ms} end=#{end_ms} probes=#{probes}"
  lines.join("\n") + "\n"
end

# received = 16 x (1 drain inside the flood + 1 after it) = 32... here two drains inside plus one after => 48
ok = EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 1900, 2400], rejected: 500 - 48))
raise "expect hb pass, got: #{ok.message}" unless ok.pass
raise "expect the derivation in the message: #{ok.message}" unless ok.message.include?("48 = 16 x 3 <= 16 x (2 + 1)")
raise "expect hb fail on a NoMemoryError" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, crash: "FATAL: NoMemoryError (NoMemoryError)")).pass
raise "expect hb fail on 'Out of memory'" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, crash: "Fatal error: Out of memory.")).pass
raise "expect hb fail on a backtrace" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, crash: "Backtrace: 0x4037")).pass
raise "expect hb fail: accounting" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 400)).pass
raise "expect hb fail: received not a multiple of 16" if EvqVerdict.judge_flood_hb(hb_log(drains: [[16, 1400], [30, 2400]], rejected: 470)).pass
raise "expect hb fail: a batch above the limit" if EvqVerdict.judge_flood_hb(hb_log(drains: [[20, 1400], [40, 2400]], rejected: 460)).pass
raise "expect hb fail: more received than the drains allow" if EvqVerdict.judge_flood_hb(hb_log(drains: [[16, 1400], [32, 2400], [48, 2500], [64, 2600]], rejected: 436)).pass
raise "expect hb fail: no per-handle line" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, refused_lines: [])).pass
raise "expect hb fail: two per-handle lines" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, refused_lines: Array.new(2) { "handle 67 holds 16 values Ruby has not popped; refusing newer writes to it until Ruby pops" })).pass
raise "expect hb fail: the line names another handle" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, refused_lines: ["handle 68 holds 16 values Ruby has not popped; refusing newer writes to it until Ruby pops"])).pass
raise "expect hb fail: the line names another count" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, refused_lines: ["handle 67 holds 17 values Ruby has not popped; refusing newer writes to it until Ruby pops"])).pass
raise "expect hb fail: a second-handle write stalled" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, probe_latencies: Array.new(49, 12) + [400])).pass
raise "expect hb fail: a second-handle write never arrived" if EvqVerdict.judge_flood_hb(hb_log(drain_times: [1400, 2400], rejected: 468, probe_latencies: Array.new(49, 12))).pass
raise "expect hb fail: no done line" if EvqVerdict.judge_flood_hb("[rigapp] flood received=16 bytes=2048 t=1400\n").pass
raise "expect hb fail: nothing received" if EvqVerdict.judge_flood_hb(hb_log(drains: [], rejected: 500)).pass

line = "handle 67 holds 16 values Ruby has not popped; refusing newer writes to it until Ruby pops"
cont_ok = "[rig] flood done n=500 rejected=0\n[rigapp] flood received=500 bytes=64000\n"
raise "expect explained pass with nothing rejected" unless EvqVerdict.judge_flood_explained(cont_ok).pass
raise "expect explained fail: a line without a rejection" if EvqVerdict.judge_flood_explained(line + "\n" + cont_ok).pass
cont_rej = "#{line}\n[rig] flood done n=500 rejected=12\n[rigapp] flood received=488 bytes=62464\n"
raise "expect explained pass: 12 rejections with the per-handle line" unless EvqVerdict.judge_flood_explained(cont_rej).pass
raise "expect explained fail: rejections without the line" if EvqVerdict.judge_flood_explained(cont_rej.sub(line, "")).pass
raise "expect explained fail: accounting" if EvqVerdict.judge_flood_explained(cont_rej.sub("488", "480")).pass
raise "expect explained fail: max_rejected" if EvqVerdict.judge_flood_explained(cont_rej, max_rejected: 0).pass

# a port log line pushed into the middle of a Ruby line (same UART) does not lose the probe
split = hb_log(drain_times: [1400, 1900, 2400], rejected: 500 - 48)
first_probe = split[/^\[rigapp\] wlat tin=1000 t=1012$/]
cut = first_probe.sub("wlat ", "wlat") .sub("tin=1000", "W (1500) prb_ble_evq: x\n tin=1000")
raise "expect the fixture to contain the split" unless cut.include?("wlatW (1500)")
split_log = split.sub(first_probe, cut)
raise "expect hb pass with a port line inside a Ruby line, got: #{EvqVerdict.judge_flood_hb(split_log).message}" unless EvqVerdict.judge_flood_hb(split_log).pass

puts "evq_verdict_test OK"
