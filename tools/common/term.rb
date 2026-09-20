# The R2P2 line editor probes the terminal with \e[6n and \e[5n and swallows
# typed input until it gets an answer. Every tool that types at the shell must
# reply, or its command line is silently dropped and only a bare prompt comes
# back. The probe runs once at boot (Shell.new sizes the terminal), so tools
# that reset the board before talking to it (see Reset.pulse callers) see it
# again on every run.
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

  SHELL_BANNER = "Starting shell"
  SHELL_PROMPT = "$>"

  # Wake the shell and answer its queries until "$>" comes back (or on a
  # board that never prints a banner, until quiet).
  #
  # Confirmed on Chain DualKey (Task 8, ESP32): the shell prints its banner
  # and terminal queries unprompted but never its own "$>" — it needs a
  # "\r\n" nudge, sent the instant "Starting shell" is first seen (not after
  # waiting for the boot burst to go quiet — an earlier version of this
  # method did that on a theory that nudging immediately was too early, but
  # that was never the real problem; see docs/spec.md §9's console-routing
  # entry for what actually blocked input for a while). On a board that
  # never resets on open (Pico 2 W) and is already idle, there is no banner
  # to wait for, so this falls back to nudging once the line goes quiet.
  #
  # "$>" is checked only in bytes received AFTER the nudge (`post`, not the
  # full `seen` buffer): the two characters can appear by coincidence inside
  # the ESP-IDF boot log itself, well before the real banner, which would
  # otherwise be mistaken for the prompt.
  #
  # limit: 40.0 — confirmed on Chain DualKey (Task 8) that the boot burst
  # alone (reset through "Starting shell") can take 20-25s (a WiFi config
  # probe runs during boot and doesn't fail fast), so a shorter window can
  # time out before the banner ever arrives.
  def self.settle(sp, quiet: 0.5, limit: 40.0)
    pending = +""
    seen    = +""
    post    = +""
    nudged  = false
    t0   = Time.now
    last = Time.now
    while Time.now - t0 < limit
      c = sp.read
      if c && !c.empty?
        seen << c
        pending << c
        post << c if nudged
        answer(sp, pending)
        last = Time.now
      end
      if !nudged && seen.include?(SHELL_BANNER)
        sp.write("\r\n")
        nudged = true
      end
      break if nudged && post.include?(SHELL_PROMPT)
      if !nudged && Time.now - last > quiet
        sp.write("\r\n")
        nudged = true
      end
      sleep 0.05
    end
    pending
  end
end
