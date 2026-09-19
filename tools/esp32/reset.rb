# Pulse RTS to reset a running ESP32 board back to normal execution.
# Ported from stackchan-picoruby's `rake r2p2:reset` (CoreS3, Python/pyserial)
# to Ruby + the serialport gem — same RTS/DTR reset circuit most ESP32 dev
# boards (including Chain DualKey) share.
#   ruby reset.rb [port]
require "serialport"

module Reset
  PULSE_SECONDS = 0.15

  module_function

  # sp: an already-open SerialPort-like object responding to dtr=, rts=.
  # sleep_fn: injected so tests don't burn 0.15 real seconds.
  def pulse(sp, sleep_fn: method(:sleep))
    sp.dtr = 0
    sp.rts = 1
    sleep_fn.call(PULSE_SECONDS)
    sp.rts = 0
  end
end

if $PROGRAM_NAME == __FILE__
  def default_port
    # Same product-name lookup as tools/esp32/*.rb generally (Task 5) — a bare
    # /dev/cu.usbmodem* glob is wrong once a Pico 2 W is also plugged in.
    out = `ioreg -w 0 -r -n "USB JTAG/serial debug unit" -l 2>/dev/null`
    ports = out.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
    raise "R2P2 board not found on USB (is the ESP32 plugged in?)" if ports.empty?
    ports.first
  end

  port = ARGV[0] || default_port
  sp = SerialPort.new(port, 115_200, 8, 1, SerialPort::NONE)
  begin
    Reset.pulse(sp)
    puts "[reset] pulsed RTS on #{port}"
  ensure
    sp.close
  end
end
