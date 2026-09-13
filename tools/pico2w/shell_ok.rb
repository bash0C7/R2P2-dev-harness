# Report whether the R2P2 shell answers, without ever wedging this process.
# Prints OK or DEAD and exits 0 / 1. The open happens in a forked child that is
# SIGKILLed if it does not return, so a hung board cannot block the caller.
#
# OK means the "$>" prompt came back, not merely that bytes did: a board that
# hangs while loading /etc/init.d/r2p2 still prints its boot banner first.
# The line editor draws the prompt only after its terminal probes are answered.
require_relative "term"

def r2p2_ports
  `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
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
    fd = IO.sysopen(dev, File::RDWR | File::NONBLOCK | File::NOCTTY)
    io = IO.for_fd(fd)
    io.write_nonblock("\r\n") rescue nil
    replier = Object.new
    replier.define_singleton_method(:write) { |s| io.write_nonblock(s) rescue nil }
    got = +""
    pending = +""
    12.times do
      chunk = (io.read_nonblock(2048) rescue "")
      got << chunk
      pending << chunk
      Term.answer(replier, pending)
      break if got.include?("$>")
      sleep 0.25
    end
    w.write(got)
  rescue => e
    w.write("ERR #{e.class}")
  end
  w.close
  exit! 0
end
w.close
alive = true
24.times { break if (alive = !Process.waitpid(pid, Process::WNOHANG)) == false; sleep 0.25 }
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
unless out.include?("$>")
  puts "DEAD (#{dev}: no prompt, got #{out[0, 60].inspect})"
  exit 1
end
puts "OK (#{dev})"
