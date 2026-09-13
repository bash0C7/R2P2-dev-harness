# Run a command with a hard wall-clock limit.
#   ruby tmo.rb <seconds> <command> [args...]
# Exits 124 on timeout. The child runs in its own process group and the whole
# group is SIGKILLed, because a serial open that blocks in the kernel ignores
# SIGTERM and would otherwise hold the port forever.
secs = ARGV.shift.to_f
pid = Process.spawn(*ARGV, pgroup: true)
deadline = Time.now + secs
loop do
  if Process.waitpid(pid, Process::WNOHANG)
    exit($?.exitstatus || 0)
  end
  if Time.now > deadline
    Process.kill("-KILL", pid) rescue nil
    Process.waitpid(pid) rescue nil
    warn "tmo: killed after #{secs}s: #{ARGV.join(' ')}"
    exit 124
  end
  sleep 0.2
end
