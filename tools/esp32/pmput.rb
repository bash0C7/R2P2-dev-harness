# PicoModem upload to the R2P2 shell.
#   ruby pmput.rb <src> <dst> [port]
#
# Confirmed on Chain DualKey (Task 8): merely opening this board's USB
# Serial/JTAG port resets it, so there is no such thing as "an
# already-running shell" to attach to without a reset pulse — every open
# starts a fresh boot. macOS's read of this board's native USB Serial/JTAG
# also occasionally stalls partway through the boot burst for no
# discoverable reason (roughly 1 in 2 single attempts). Deploy::Picomodem.upload
# already retries the whole reset+await_shell+offer cycle a few times for
# exactly this kind of failure, so this just delegates to it instead of
# hand-rolling a single unretried attempt.
require_relative "../common/device_lock"
DeviceLock.hold("esp32")
require_relative "../common/picomodem"
PM = Deploy::Picomodem

def default_port
  out = `ioreg -w 0 -r -n "USB JTAG/serial debug unit" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  if ports.empty?
    raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)"
  end
  ports.first
end

src  = ARGV[0]
dst  = ARGV[1]
port = ARGV[2] || default_port

begin
  PM.upload(src: src, dst: dst, port: port)
  puts "[pmput] OK"
rescue => e
  abort "[pmput] FAILED: #{e.message}"
end
