# Run a script on the R2P2 shell and capture stdout for N seconds, then Ctrl-C.
#   ruby runapp.rb <device path> <seconds> [port]
require "serialport"
require_relative "term"

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

path = ARGV[0]
secs = (ARGV[1] || "20").to_f
port = ARGV[2] || default_port
sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
sp.read_timeout = 100
Term.settle(sp)
sp.write(path + "\r\n")
t0 = Time.now
buf = +""
while Time.now - t0 < secs
  c = sp.read
  if c && !c.empty?
    buf << c
    Term.answer(sp, c.dup)
    $stdout.print c.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
    $stdout.flush
  end
  sleep 0.05
end
sp.write("\x03")   # Ctrl-C to stop the app
sleep 0.5
sp.close
