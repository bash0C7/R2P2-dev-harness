# Send Ctrl-C to the R2P2 shell port, to stop an autostarted /home/app.rb and
# bring the "$>" prompt back.
#   ruby interrupt.rb [port]
require_relative "../common/device_lock"
DeviceLock.hold("esp32")
port = ARGV[0] || `ioreg -w 0 -r -n "USB JTAG/serial debug unit" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort.first
abort "R2P2 board not found on USB" unless port
io = IO.for_fd(IO.sysopen(port, File::RDWR | File::NONBLOCK | File::NOCTTY), autoclose: false)
io.write_nonblock("\x03")
puts "[interrupt] Ctrl-C sent to #{port}"
exit! 0
