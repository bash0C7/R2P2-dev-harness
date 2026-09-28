require_relative "evq_verdict"

log = <<~LOG
  [rig] inject seq=1 t=1000
  [rigapp] recv seq=1 t=1004
LOG
r = EvqVerdict.judge(log, max_latency_ms: 50)
raise "expect pass, got: #{r.message}" unless r.pass

log2 = "[rig] inject seq=1 t=1000\n[rigapp] recv seq=1 t=1900\n"
raise "expect fail (latency)" if EvqVerdict.judge(log2, max_latency_ms: 50).pass

log3 = log + "[rig] FOREIGN_PUSH\n"
raise "expect fail (foreign push)" if EvqVerdict.judge(log3, max_latency_ms: 50).pass

log4 = "[rig] inject seq=1 t=1000\n" # 未到達
raise "expect fail (lost)" if EvqVerdict.judge(log4, max_latency_ms: 50).pass

puts "evq_verdict_test OK"
