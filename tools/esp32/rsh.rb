# Send a line to the R2P2 shell and capture output for N seconds.
#   ruby rsh.rb "<command>" [seconds] [port]
require "serialport"
require_relative "../common/term"

def default_port
  out = `ioreg -w 0 -r -n "USB JTAG/serial debug unit" -l 2>/dev/null`
  ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
  raise "R2P2 board not found on USB (is the ESP32 plugged in and running R2P2?)" if ports.empty?
  ports.first
end

cmd  = ARGV[0].to_s
secs = (ARGV[1] || "3").to_f
port = ARGV[2] || default_port
sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
sp.read_timeout = 100
Term.settle(sp)
sp.write(cmd + "\r\n") unless cmd.empty?
buf = +""
t0 = Time.now
while Time.now - t0 < secs
  chunk = sp.read
  if chunk && !chunk.empty?
    buf << chunk
    Term.answer(sp, chunk.dup)
  end
  sleep 0.05
end
sp.close
print buf.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
