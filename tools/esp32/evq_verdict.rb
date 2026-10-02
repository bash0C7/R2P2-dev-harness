# Judge a BLE event-path QEMU log from the qemu-ble-evq rig
# (firmware-patches/qemu-ble-evq). The rig's injector task logs each ring
# insertion, the Ruby test app logs each arrival, and the overlay logs
# FOREIGN_PUSH when the Ruby queue is pushed from outside the VM thread.
# The injector also pushes two GATT writes through the port's write
# queue; the second ("B") must reach Ruby (the first is the one a
# fault-injection run makes raise, see expect_fault).
# Pass = every injected seq arrived, within max_latency_ms, with no
# foreign push, and write "B" was delivered.
module EvqVerdict
  Result = Struct.new(:pass, :message, keyword_init: true)

  INJECT = /\[rig\] inject seq=(\d+) t=(\d+)/
  RECV = /\[rigapp\] recv seq=(\d+) t=(\d+)/
  FOREIGN_PUSH = "[rig] FOREIGN_PUSH".freeze
  WRITE_B = '[rigapp] write h=0x42 v="B"'.freeze
  FAULT = "[rig] FAULT write".freeze

  module_function

  # expect_fault: the overlay was applied with the BLE_write_data fault
  # hook (EVQ_OOM=1), so the log must show the fault firing — otherwise a
  # pass would only prove the hook never ran.
  def judge(log, max_latency_ms:, expect_fault: false)
    injected = {}
    received = {}
    log.scan(INJECT) { |seq, t| injected[seq.to_i] ||= t.to_i }
    log.scan(RECV) { |seq, t| received[seq.to_i] ||= t.to_i }

    problems = []
    problems << "no inject lines in log" if injected.empty?
    problems << "FOREIGN_PUSH detected (queue pushed off the VM thread)" if log.include?(FOREIGN_PUSH)
    problems << "write B never reached Ruby" unless log.include?(WRITE_B)
    problems << "fault hook did not fire" if expect_fault && !log.include?(FAULT)

    lost = injected.keys - received.keys
    problems << "lost seq: #{lost.join(',')}" unless lost.empty?

    late = injected.filter_map do |seq, t_in|
      t_out = received[seq] or next
      latency = t_out - t_in
      "seq=#{seq} #{latency}ms" if latency > max_latency_ms
    end
    problems << "latency > #{max_latency_ms}ms: #{late.join(', ')}" unless late.empty?

    if problems.empty?
      worst = injected.map { |seq, t_in| received[seq] - t_in }.max
      Result.new(pass: true,
                 message: "#{injected.size} events delivered, worst latency #{worst}ms <= #{max_latency_ms}ms, " \
                          "no foreign push, write B delivered#{expect_fault ? ' after the injected fault' : ''}")
    else
      Result.new(pass: false, message: problems.join("; "))
    end
  end
end
