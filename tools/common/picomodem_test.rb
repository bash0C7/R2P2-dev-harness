# tools/common/picomodem_test.rb
require "minitest/autorun"
require "stringio"
require_relative "picomodem"

# StringIO doesn't have wait_readable or read_nonblock; add them for tests.
# Since buffered data is already available, these always succeed immediately.
class StringIO
  def wait_readable(timeout = nil)
    true
  end

  def read_nonblock(size, exception: true)
    read(size)
  end
end

class PicomodemTest < Minitest::Test
  PM = Deploy::Picomodem

  def test_crc16_is_stable_for_the_same_input
    assert_equal PM.crc16("hello"), PM.crc16("hello")
  end

  def test_crc16_differs_for_different_input
    refute_equal PM.crc16("hello"), PM.crc16("world")
  end

  def test_make_frame_round_trips_through_recv_frame
    frame = PM.make_frame(PM::FILE_WRITE, "payload")
    io = StringIO.new(frame)
    cmd, body = PM.recv_frame(io, timeout: 1.0)
    assert_equal PM::FILE_WRITE, cmd
    assert_equal "payload", body
  end

  def test_recv_frame_rejects_a_corrupted_crc
    frame = PM.make_frame(PM::FILE_WRITE, "payload").b
    frame[-1] = (frame.getbyte(-1) ^ 0xFF).chr
    io = StringIO.new(frame)
    assert_nil PM.recv_frame(io, timeout: 1.0)
  end

  def test_answer_queries_answers_cursor_and_dsr_queries
    class << (sp = Object.new)
      attr_reader :written
      def write(s); (@written ||= []) << s; end
    end
    buf = "\e[6n\e[5n".dup
    replies = PM.answer_queries(sp, buf)
    assert_equal 2, replies
    assert_equal [PM::CURSOR_REPLY, PM::DSR_REPLY], sp.written
  end
end
