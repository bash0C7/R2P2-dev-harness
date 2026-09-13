# PicoModem upload to an ALREADY-RUNNING R2P2 shell (no reset pulse).
#   ruby pmput.rb <src> <dst> [port]

require_relative "picomodem"
PM = Deploy::Picomodem

def default_port
  # Resolve the R2P2 board by USB product name. A bare /dev/cu.usbmodem* glob
  # is WRONG when an ESP32 is also plugged in: its node sorts first, and
  # opening it resets that board.
  out = `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  if ports.empty?
    raise "R2P2 board not found on USB (is the Pico plugged in and running R2P2?)"
  end
  ports.first   # lowest = CDC0 = the R2P2 shell
end

src  = ARGV[0]
dst  = ARGV[1]
port = ARGV[2] || default_port

content = File.binread(src)
payload = [content.bytesize].pack("N") + dst
puts "[pmput] #{src} -> #{dst} (#{content.bytesize} bytes) on #{port}"

serial = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
begin
  serial.write("\r\n")           # wake the prompt
  PM.settle(serial, $stdout)
  reason = PM.offer_file_write(serial, payload, $stdout, 1)
  abort "[pmput] FAILED: #{reason}" if reason
  PM.send_chunks(serial, content, $stdout)
  puts "[pmput] OK"
ensure
  serial.close
end
