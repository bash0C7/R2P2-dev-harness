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

puts "evq_verdict_test OK"
