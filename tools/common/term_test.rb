require "minitest/autorun"
require_relative "term"

class TermTest < Minitest::Test
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
  end

  def test_answer_replies_to_a_cursor_query
    sp  = FakeSerial.new
    buf = "\e[6n".dup
    sent = Term.answer(sp, buf)
    assert_equal 1, sent
    assert_equal [Term::CURSOR_REPLY], sp.written
    assert_equal "", buf
  end

  def test_answer_replies_to_a_dsr_query
    sp  = FakeSerial.new
    buf = "\e[5n".dup
    sent = Term.answer(sp, buf)
    assert_equal 1, sent
    assert_equal [Term::DSR_REPLY], sp.written
  end

  def test_answer_handles_multiple_queries_in_one_buffer
    sp  = FakeSerial.new
    buf = "noise\e[6nmore\e[5nend".dup
    sent = Term.answer(sp, buf)
    assert_equal 2, sent
    assert_equal [Term::CURSOR_REPLY, Term::DSR_REPLY], sp.written
    assert_equal "noisemoreend", buf
  end

  def test_answer_returns_zero_when_nothing_to_answer
    sp  = FakeSerial.new
    buf = "plain text".dup
    assert_equal 0, Term.answer(sp, buf)
    assert_empty sp.written
  end

  def test_settle_answers_then_returns_once_quiet
    sp = FakeSerial.new(["\e[6n", nil, nil, nil, nil])
    pending = Term.settle(sp, quiet: 0.05, limit: 1.0)
    assert_includes sp.written, Term::CURSOR_REPLY
    assert_equal "", pending
  end
end
