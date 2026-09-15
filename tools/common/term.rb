# The R2P2 line editor probes the terminal with \e[6n and \e[5n and swallows
# typed input until it gets an answer. Every tool that types at the shell must
# reply, or its command line is silently dropped and only a bare prompt comes
# back. Opening the port re-arms the probe, so this runs on each connection.
module Term
  CURSOR_QUERY = "\e[6n"
  CURSOR_REPLY = "\e[1;1R"
  DSR_QUERY    = "\e[5n"
  DSR_REPLY    = "\e[0n"

  # Answer and consume every query sitting in buf. Returns how many were sent.
  def self.answer(sp, buf)
    sent = 0
    loop do
      if buf.sub!(CURSOR_QUERY, "")
        sp.write(CURSOR_REPLY)
        sent += 1
      elsif buf.sub!(DSR_QUERY, "")
        sp.write(DSR_REPLY)
        sent += 1
      else
        return sent
      end
    end
  end

  # Wake the shell and answer its queries until the device goes quiet.
  def self.settle(sp, quiet: 0.5, limit: 8.0)
    sp.write("\r\n")
    pending = +""
    t0 = Time.now
    last = Time.now
    while Time.now - t0 < limit
      c = sp.read
      if c && !c.empty?
        pending << c
        answer(sp, pending)
        last = Time.now
      elsif Time.now - last > quiet
        break
      end
      sleep 0.05
    end
    pending
  end
end
