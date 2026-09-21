# Report whether the R2P2 shell answers, without ever wedging this process.
# Prints OK or DEAD and exits 0 / 1.
#
# CAUTION (ESP32-specific, unlike Pico 2 W): this check is NOT a
# side-effect-free liveness probe — it pulses RTS to reset the board first,
# same as reset.rb, and then waits for it to come back up to "$>".
#
# Two things confirmed on Chain DualKey in Task 8:
# - The shell prints its banner (down through "Starting shell...") and a
#   couple of "\e[5n" queries entirely on its own, but does NOT print its
#   "$>" prompt on its own — it needs one "\r\n" sent after the banner, same
#   as tools/common/term.rb's Term.settle does for an already-running shell.
# - macOS's read of this board's native USB Serial/JTAG occasionally stalls
#   partway through the boot burst for no discoverable reason (roughly 1 in
#   2 single attempts, cutting off at an arbitrary line) even though a
#   fresh reset+read attempt right after reliably goes all the way through.
#   So this retries the whole reset+read a few times rather than trusting
#   one attempt, each attempt on its own freshly-opened connection.
# - Boot to "Starting shell..." can itself take 20-25s (a WiFi config probe
#   runs during boot and doesn't fail fast), so each attempt's window has to
#   be generous, not just a few seconds.
# - "$>" can appear by coincidence inside the ESP-IDF boot log noise itself
#   (well before the real shell banner, let alone a nudge) — checking the
#   whole cumulative buffer for it is a false-positive trap. Only bytes
#   received AFTER the nudge count as a real prompt.
require_relative "../common/device_lock"
DeviceLock.hold("esp32")
require "serialport"
require_relative "reset"
require_relative "../common/term"

def r2p2_ports
  `ioreg -w 0 -r -n "USB JTAG/serial debug unit" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
end

dev = ARGV[0] || r2p2_ports.first
unless dev
  puts "DEAD (not enumerated)"
  exit 1
end

r, w = IO.pipe
pid = fork do
  r.close
  begin
    got = +""
    post = +""
    3.times do |attempt|
      sleep 2 if attempt.positive?
      sp = SerialPort.new(dev, 115_200, 8, 1, SerialPort::NONE)
      sp.read_timeout = 100
      Reset.pulse(sp)
      got = +""
      post = +""
      pending = +""
      nudged = false
      350.times do
        chunk = (sp.read rescue nil)
        if chunk && !chunk.empty?
          got << chunk
          pending << chunk
          post << chunk if nudged
          Term.answer(sp, pending)
        end
        if !nudged && got.include?("Starting shell...")
          sp.write("\r\n")
          nudged = true
        end
        break if post.include?("$>")
      end
      sp.close
      break if post.include?("$>")
    end
    w.write(post.include?("$>") ? "OK#{got}" : "NOPROMPT#{post}")
  rescue => e
    w.write("ERR #{e.class}")
  end
  w.close
  exit! 0
end
w.close
alive = true
700.times { break if (alive = !Process.waitpid(pid, Process::WNOHANG)) == false; sleep 0.25 }
if alive
  Process.kill("KILL", pid) rescue nil
  Process.waitpid(pid) rescue nil
  puts "DEAD (#{dev}: open wedged)"
  exit 1
end
out = r.read.to_s
r.close
if out.empty? || out.start_with?("ERR")
  puts "DEAD (#{dev}: #{out.empty? ? 'silent' : out})"
  exit 1
end
if out.start_with?("NOPROMPT")
  post = out[8..]
  puts "DEAD (#{dev}: banner seen and nudged, but no \"$>\" reply — " \
       "post-nudge bytes (#{post.bytesize}): #{post[0, 200].inspect})"
  exit 1
end
puts "OK (#{dev})"
