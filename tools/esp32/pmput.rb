# PicoModem upload to an ALREADY-RUNNING R2P2 shell (no reset pulse).
#   ruby pmput.rb <src> <dst> [port]
require_relative "../common/picomodem"
PM = Deploy::Picomodem

def default_port
  # A bare /dev/cu.usbmodem* glob is wrong once a Pico 2 W is also plugged
  # in: sort order and product name both need checking on real hardware
  # (Task 8) — this filter is a starting point, not yet confirmed.
  out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  if ports.empty?
    raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)"
  end
  ports.first
end

src  = ARGV[0]
dst  = ARGV[1]
port = ARGV[2] || default_port

content = File.binread(src)
payload = [content.bytesize].pack("N") + dst
puts "[pmput] #{src} -> #{dst} (#{content.bytesize} bytes) on #{port}"

serial = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
begin
  serial.write("\r\n")
  PM.settle(serial, $stdout)
  reason = PM.offer_file_write(serial, payload, $stdout, 1)
  abort "[pmput] FAILED: #{reason}" if reason
  PM.send_chunks(serial, content, $stdout)
  puts "[pmput] OK"
ensure
  serial.close
end
