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

  def firmware_output(log)
    start = log.index(RIG_RUN_START)
    start ? log[start..] : log
  end

  def seq_ranges(seqs)
    seqs.sort.slice_when { |a, b| b != a + 1 }.map { |r| r.size == 1 ? r.first.to_s : "#{r.first}-#{r.last}" }.join(",")
  end
end
