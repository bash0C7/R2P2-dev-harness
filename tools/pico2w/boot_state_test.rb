require "minitest/autorun"
require_relative "boot_state"

class BootStateTest < Minitest::Test
  class FakeSerial
    attr_reader :written

    def initialize(chunks = [])
      @written = []
      @chunks  = chunks
    end

    def write(s)
      @written << s
    end

    def read
      @chunks.shift
    end

    def chunks_left
      @chunks.size
    end
  end

  # Real capture off a Pico 2 W (rp2040:reboot, no autostart app):
  #   Initializing FLASH disk as the root volume...
  #   Press 's' to skip running /etc/init.d/r2p2
  #   ....................
  #   Loading /etc/init.d/r2p2...
  #   No app found
  #   $>
  def test_classify_shell_when_prompt_seen
    buf = "Initializing FLASH disk as the root volume... \n" \
          "Press 's' to skip running /etc/init.d/r2p2\n....................\n" \
          "Loading /etc/init.d/r2p2...\nNo app found\n$> "
    assert_equal :shell, BootState.classify(buf)
  end

  # Real capture with /home/app.rb autostarting: the app-loading line has no
  # "/home/" prefix and no trailing "..." (unlike the bootstrap line above).
  #   Loading /etc/init.d/r2p2...
  #   Loading app.rb
  #   <app's own output, no "$>" -- it owns the terminal>
  def test_classify_app_when_an_app_is_loading_without_a_prompt_yet
    buf = "Initializing FLASH disk as the root volume... \n" \
          "Press 's' to skip running /etc/init.d/r2p2\n....................\n" \
          "Loading /etc/init.d/r2p2...\nLoading app.rb\ndummy app running\n"
    assert_equal :app, BootState.classify(buf)
  end

  def test_classify_app_for_a_dfu_resolved_path_too
    buf = "Loading /etc/init.d/r2p2...\nLoading /some/dfu/resolved/path.mrb\n"
    assert_equal :app, BootState.classify(buf)
  end

  def test_classify_hung_when_stuck_loading_init_with_no_further_progress
    buf = "Initializing FLASH disk as the root volume... \n" \
          "Press 's' to skip running /etc/init.d/r2p2\n....................\n" \
          "Loading /etc/init.d/r2p2...\n"
    assert_equal :hung, BootState.classify(buf)
  end

  def test_classify_unknown_when_nothing_seen_yet
    assert_equal :unknown, BootState.classify("")
    assert_equal :unknown, BootState.classify("Initializing FLASH disk as the root volume... \n")
  end

  def test_classify_prefers_shell_even_if_an_app_ran_and_exited_first
    buf = "Loading app.rb\nNo app found\n$> "
    assert_equal :shell, BootState.classify(buf)
  end

  def test_read_answers_terminal_queries_while_reading
    sp = FakeSerial.new(["\e[6n", "$> "])
    buf = BootState.read(sp, budget: 1.0, sleep_step: 0.01)
    assert_includes sp.written, Term::CURSOR_REPLY
    assert_equal :shell, BootState.classify(buf)
  end

  def test_read_stops_early_once_an_app_is_confirmed
    sp = FakeSerial.new(["Loading app.rb\n", "this chunk must never be read"])
    buf = BootState.read(sp, budget: 1.0, sleep_step: 0.01)
    assert_equal :app, BootState.classify(buf)
    assert_equal 1, sp.chunks_left
  end

  def test_read_does_not_stop_early_just_because_init_is_still_loading
    # "Loading /etc/init.d/r2p2..." alone prints during a completely normal
    # boot too -- read must keep going past it, not conclude :hung the
    # instant it appears.
    sp = FakeSerial.new(["Loading /etc/init.d/r2p2...\n", "Loading app.rb\n"])
    buf = BootState.read(sp, budget: 1.0, sleep_step: 0.01)
    assert_equal :app, BootState.classify(buf)
    assert_equal 0, sp.chunks_left
  end

  def test_read_returns_whatever_it_saw_when_the_budget_runs_out
    sp = FakeSerial.new([nil, nil])
    buf = BootState.read(sp, budget: 0.05, sleep_step: 0.02)
    assert_equal "", buf
  end
end
