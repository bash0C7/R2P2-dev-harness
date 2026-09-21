# Send Ctrl-C to the R2P2 shell port, to stop an app such as an autostarted
# /home/app.rb and bring the "$>" prompt back.
#   ruby interrupt.rb [port]
# Opens non-blocking and never closes the fd: close can block on a board that
# is not reading CDC.
require_relative "../common/device_lock"
DeviceLock.hold("rp2040")
port = ARGV[0] || `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort.first
abort "R2P2 board not found on USB" unless port
io = IO.for_fd(IO.sysopen(port, File::RDWR | File::NONBLOCK | File::NOCTTY), autoclose: false)
io.write_nonblock("\x03")
puts "[interrupt] Ctrl-C sent to #{port}"
exit! 0
