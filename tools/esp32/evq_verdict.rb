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
  WRITE_A = /write h=0x42 v="A"/
  WRITE_B = /write h=0x42 v="B"/
  FAULT = /FAULT write/
  FLOOD_DONE = /flood done n=(\d+) rejected=(\d+)/
  FLOOD_RECV = /flood received=(\d+) bytes=(\d+)/
  FLOOD_CRASH = /Fatal error: Out of memory|NoMemoryError|Guru Meditation|abort\(\) was called|Rebooting/
  FLOOD_DROP = /write queue full/
  WLAT = /wlat tin=(\d+) t=(\d+)/

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

  def judge_flood(log, max_rejected: nil)
    problems = []
    crash = log[FLOOD_CRASH]
    problems << "crash pattern matched: #{crash}" if crash
    done_match = FLOOD_DONE.match(log)
    problems << "no flood-done line with rejected count in log" if done_match.nil?
    received = nil
    if done_match
      after = log[done_match.end(0)..]
      problems << "no flood received= line after flood done" unless after.match?(FLOOD_RECV)
      sent = done_match[1].to_i
      rejected = done_match[2].to_i
      received = log.scan(FLOOD_RECV).last&.first.to_i
      problems << "accounting: received #{received} + rejected #{rejected} != sent #{sent}" if received + rejected != sent
      problems << "rejected #{rejected} > #{max_rejected}" if max_rejected && rejected > max_rejected
    end

    if problems.empty?
      drops = log.scan(FLOOD_DROP).size
      Result.new(pass: true,
                 message: "flood received=#{received} rejected=#{done_match[2]} sent=#{done_match[1]}, write-queue-full warnings=#{drops}")
    else
      Result.new(pass: false, message: problems.join("; "))
    end
  end
end
