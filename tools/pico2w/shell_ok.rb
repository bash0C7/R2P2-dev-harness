# Report whether the R2P2 shell answers, without ever wedging this process.
# Prints OK or DEAD and exits 0 / 1. The open happens in a forked child that is
# SIGKILLed if it does not return, so a hung board cannot block the caller.
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
    got = +""
    12.times do
      got << (io.read_nonblock(2048) rescue "")
      break unless got.empty?
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
puts "OK (#{dev})"
