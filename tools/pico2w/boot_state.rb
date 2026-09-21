# Classify what's on the other end of the R2P2 shell's CDC0 port right now,
# without the caller having to blind-wait for a "$>" that may never come.
#   ruby boot_state.rb [device] [enumerate_wait] [read_budget]
# Prints one of: shell / app / hung / unknown, and exits 0.
#
# Opening the instant the board re-enumerates catches the boot sequence from
# its start ("Initializing FLASH disk..." -> "Loading /etc/init.d/r2p2..." ->
# "Loading <app>.rb" / "No app found" -> "$>"), so the state is usually known
# within a couple of seconds -- far short of blind-waiting the full 20s that
# an autostarted app (which never prints "$>") used to cost every boot.
#
# Opens non-blocking and never closes: closing can block on a wedged board
# (same reasoning as shell_ok.rb).
require_relative "../common/term"

module BootState
  # Confirmed on real hardware (vendor/picoruby's picoruby-shell): the r2p2
  # init script prints a bare "Loading app.rb" / "Loading app.mrb" / "Loading
  # <dfu-resolved path>" (no "/home/" prefix, no trailing "..."), while
  # Shell.bootstrap's own "Loading <file>..." for /etc/init.d/r2p2 itself
  # always ends in "...". Match by excluding the init.d line rather than by
  # a "/home/"-prefixed shape, which the real output never has.
  APP_LOADING = %r{^Loading (?!.*init\.d/r2p2).+$}.freeze
  INIT_LOADING = "init.d/r2p2"

  # $> wins even if an app ran and exited first (e.g. "No app found" then the
  # shell comes up) -- shell is the terminal state we actually care about.
  def self.classify(buf)
    return :shell if buf.include?(Term::SHELL_PROMPT)
    return :app if buf.match?(APP_LOADING)
    return :hung if buf.include?(INIT_LOADING)
    :unknown
  end

  # Reads sp for up to budget seconds, answering terminal queries as they
  # arrive, and returns early only once a *positive* state is confirmed
  # (:shell or :app -- seeing "Loading /etc/init.d/r2p2" alone does not
  # return early: that line prints during a completely normal boot too, so
  # only silence for the *whole* budget after it means :hung, not the
  # instant it first appears). sp needs #write and #read, the same duck type
  # Term already expects (see term_test.rb's FakeSerial).
  def self.read(sp, budget:, sleep_step: 0.1)
    buf = +""
    pending = +""
    t0 = Time.now
    while Time.now - t0 < budget
      chunk = sp.read
      if chunk && !chunk.empty?
        buf << chunk
        pending << chunk
        Term.answer(sp, pending)
        state = classify(buf)
        return buf if state == :shell || state == :app
      end
      sleep sleep_step
    end
    buf
  end
end

if $PROGRAM_NAME == __FILE__
  require_relative "../common/device_lock"
  DeviceLock.hold("rp2040")
  def r2p2_ports
    `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  end

  dev = ARGV[0]
  dev = nil if dev && dev.empty?
  enumerate_wait = (ARGV[1] || "15").to_f
  # Measured on real Pico 2 W hardware: enumerate + boot-to-"$>" together
  # take ~4.2s consistently across a normal reboot (see rp2040.rake's
  # wait_for_booted_shell! for why this matters -- it used to blind-wait up
  # to 20s). 10s leaves ample margin without giving up much of the speedup.
  read_budget = (ARGV[2] || "10").to_f

  unless dev
    deadline = Time.now + enumerate_wait
    dev = r2p2_ports.first
    until dev || Time.now > deadline
      sleep 0.1
      dev = r2p2_ports.first
    end
  end

  unless dev
    puts "unknown"
    exit 0
  end

  fd = IO.sysopen(dev, File::RDWR | File::NONBLOCK | File::NOCTTY)
  io = IO.for_fd(fd, autoclose: false)
  adapter = Object.new
  adapter.define_singleton_method(:write) { |s| io.write_nonblock(s) rescue nil }
  adapter.define_singleton_method(:read) { (io.read_nonblock(2048) rescue nil) }

  buf = BootState.read(adapter, budget: read_budget)
  puts BootState.classify(buf)
end
