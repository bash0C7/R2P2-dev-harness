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

puts "evq_verdict_test OK"
