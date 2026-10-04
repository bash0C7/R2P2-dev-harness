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

puts "evq_verdict_test OK"
