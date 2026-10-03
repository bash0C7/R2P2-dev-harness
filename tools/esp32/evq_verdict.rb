# Judge a BLE event-path QEMU log from the qemu-ble-evq rig
# (firmware-patches/qemu-ble-evq). The rig's injector task logs one
# summary line, the Ruby test app logs each arrival's seq/inject-time/
# receive-time, and the overlay logs FOREIGN_PUSH when the Ruby queue is
# pushed from outside the VM thread. Pass = every injected seq arrived,
# within max_latency_ms, with no foreign push.
module EvqVerdict
  Result = Struct.new(:pass, :message, keyword_init: true)

  INJECT_DONE = /inject done n=(\d+)/
  RECV = /recv seq=(\d+) tin=(\d+) t=(\d+)/
  FOREIGN_PUSH = /FOREIGN_PUSH/
  WRITE_B = /write h=0x42 v="B"/
  FAULT = /FAULT write/

  module_function

  def judge(log, max_latency_ms:, expect_fault: false)
    total = log[INJECT_DONE, 1]
    received = {}
    log.scan(RECV) { |seq, tin, t| received[seq.to_i] ||= [tin.to_i, t.to_i] }

    problems = []
    problems << "no inject-done line in log" if total.nil?
    problems << "FOREIGN_PUSH detected (queue pushed off the VM thread)" if log.match?(FOREIGN_PUSH)
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

    if problems.empty?
      worst = received.values.map { |tin, t| t - tin }.max
      Result.new(pass: true,
                 message: "#{received.size} events delivered, worst latency #{worst}ms <= #{max_latency_ms}ms, " \
                          "no foreign push, write B delivered#{expect_fault ? ' after the injected fault' : ''}")
    else
      Result.new(pass: false, message: problems.join("; "))
    end
  end
end
