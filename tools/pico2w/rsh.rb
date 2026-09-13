# Send a line to the R2P2 shell and capture output for N seconds.
#   ruby rsh.rb "<command>" [seconds] [port]
require "serialport"

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

cmd  = ARGV[0].to_s
secs = (ARGV[1] || "3").to_f
port = ARGV[2] || default_port
sp = SerialPort.new(port, 115200, 8, 1, SerialPort::NONE)
sp.read_timeout = 100
sp.write("\r\n")
sleep 0.3
sp.read rescue nil
unless cmd.empty?
  sp.write(cmd + "\r\n")
end
buf = +""
t0 = Time.now
while Time.now - t0 < secs
  chunk = sp.read
  buf << chunk if chunk && !chunk.empty?
  sleep 0.05
end
sp.close
# strip common escape sequences for readability
print buf.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
