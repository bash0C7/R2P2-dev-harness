# BleDevBridge::Framer は BLE にも DFU にも触らない純粋なバッファ操作なので、
# 実機・BTstack・picoruby-dfu の無いホストだけで全部検証できる。
class BleDevBridgeFramerTest < Picotest::Test
  def test_returns_nil_when_no_line_or_magic_is_complete_yet
    f = BleDevBridge::Framer.new
    assert_nil f.feed("1 + ")
  end

  def test_extracts_a_complete_repl_line_without_the_trailing_newline
    f = BleDevBridge::Framer.new
    assert_equal [:line, "1 + 1"], f.feed("1 + 1\n")
    assert_equal :repl, f.mode
  end

  def test_extracts_a_line_assembled_across_two_feed_calls
    f = BleDevBridge::Framer.new
    assert_nil f.feed("1 +")
    assert_equal [:line, "1 + 1"], f.feed(" 1\n")
  end

  def test_a_second_line_stays_buffered_until_its_own_newline_arrives
    f = BleDevBridge::Framer.new
    assert_equal [:line, "a"], f.feed("a\nb")
    assert_nil f.feed(nil)
    assert_equal [:line, "b"], f.feed("\n")
  end

  def test_short_input_below_magic_length_is_still_treated_as_repl
    f = BleDevBridge::Framer.new
    # "1\n" is only 2 bytes, shorter than MAGIC ("DFU\0", 4 bytes) -- must not
    # block waiting for more bytes to decide the mode.
    assert_equal [:line, "1"], f.feed("1\n")
  end

  def test_switches_to_dfu_mode_once_the_magic_bytes_are_seen
    f = BleDevBridge::Framer.new
    f.feed(BleDevBridge::Framer::MAGIC) { |_buf| nil }
    assert_equal :dfu, f.mode
  end

  def test_magic_split_across_two_feed_calls_is_still_recognized
    f = BleDevBridge::Framer.new
    assert_nil f.feed("DF") { |_buf| nil } # shorter than MAGIC: no decision yet
    f.feed("U\0") { |_buf| nil }
    assert_equal :dfu, f.mode
  end

  def test_waits_while_dfu_total_is_unknown
    f = BleDevBridge::Framer.new
    f.feed(BleDevBridge::Framer::MAGIC) { |_buf| nil } # header not fully arrived yet
    assert_equal :dfu, f.mode
    assert_nil f.feed("more bytes but still no size") { |_buf| nil }
  end

  def test_returns_the_dfu_payload_once_the_declared_total_is_reached
    f = BleDevBridge::Framer.new
    total_fn = ->(buf) { 10 <= buf.bytesize ? 10 : nil }
    f.feed(BleDevBridge::Framer::MAGIC, &total_fn) # 4 bytes, not enough yet
    result = f.feed("123456", &total_fn) # 4 + 6 = 10 bytes total
    assert_equal [:dfu_payload, "#{BleDevBridge::Framer::MAGIC}123456"], result
    assert_equal :repl, f.mode
  end

  def test_bytes_after_a_dfu_payload_in_the_same_chunk_are_kept_for_the_next_feed
    f = BleDevBridge::Framer.new
    total_fn = ->(buf) { 8 <= buf.bytesize ? 8 : nil }
    # MAGIC (4) + "1234" (4) = 8-byte payload, plus a trailing REPL line in
    # the very same feed() call.
    result = f.feed("#{BleDevBridge::Framer::MAGIC}1234tail\n", &total_fn)
    assert_equal [:dfu_payload, "#{BleDevBridge::Framer::MAGIC}1234"], result
    assert_equal :repl, f.mode
    assert_equal [:line, "tail"], f.feed(nil)
  end

  def test_mode_returns_to_repl_after_a_payload_so_the_next_line_parses_normally
    f = BleDevBridge::Framer.new
    total_fn = ->(buf) { 4 <= buf.bytesize ? 4 : nil }
    f.feed(BleDevBridge::Framer::MAGIC, &total_fn)
    assert_equal :repl, f.mode
    assert_equal [:line, "1 + 1"], f.feed("1 + 1\n")
  end
end
