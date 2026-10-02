# picotest (P9)。Picotest::Runner が板の VM に渡すスクリプトと同じ形: テストのクラス、test_* を1つずつ直接呼ぶ所、
# 最後に "----" と結果の JSON。picotest と json は PicoRuby の mrblib をそのまま使う (docs/spec.md §10「picotest と caller」)。
# host の picoruby と全行一致を見る (tools/fpga/ref_vm_test.rb)
require 'picotest'

class CalcTest < Picotest::Test
  def setup
    @base = 10
  end

  def teardown
    @base = nil
  end

  def test_pass
    assert(true)
    assert_true(1 == 1)
    assert_false(nil)
    assert_nil(nil)
    assert_not_nil(@base)
    assert_equal(12, @base + 2)
    assert_not_equal(1, 2)
    assert_in_delta(0.3, 0.1 + 0.2)
  end

  def test_fail
    assert_equal(1, 2)
    assert_nil(false)
    assert(false)
    assert_in_delta(1.0, 1.5, 0.1)
  end

  def test_raise
    assert_raise(ZeroDivisionError) { 1 / 0 }
    assert_raise(ArgumentError, "bad") { raise ArgumentError, "bad" }
    assert_raise(ArgumentError) { raise NoMethodError, "nope" }
    assert_raise(RuntimeError) { 1 }
  end

  def test_skip
    skip "not on this board"
  end

  def test_error
    nil.__no_such_method
  end
end

my_test = CalcTest.new
puts
print 'From picotest.rb:'
puts
print '  CalcTest#test_pass '
begin
  my_test.setup
  my_test.test_pass
rescue Picotest::Skip => e
  my_test.report_skip({method: 'test_pass', reason: e.message})
rescue => e
  my_test.report_exception({method: 'test_pass', raise_message: e.message})
ensure
  my_test.teardown
  my_test.clear_doubles
end
puts
print '  CalcTest#test_fail '
begin
  my_test.setup
  my_test.test_fail
rescue Picotest::Skip => e
  my_test.report_skip({method: 'test_fail', reason: e.message})
rescue => e
  my_test.report_exception({method: 'test_fail', raise_message: e.message})
ensure
  my_test.teardown
  my_test.clear_doubles
end
puts
print '  CalcTest#test_raise '
begin
  my_test.setup
  my_test.test_raise
rescue Picotest::Skip => e
  my_test.report_skip({method: 'test_raise', reason: e.message})
rescue => e
  my_test.report_exception({method: 'test_raise', raise_message: e.message})
ensure
  my_test.teardown
  my_test.clear_doubles
end
puts
print '  CalcTest#test_skip '
begin
  my_test.setup
  my_test.test_skip
rescue Picotest::Skip => e
  my_test.report_skip({method: 'test_skip', reason: e.message})
rescue => e
  my_test.report_exception({method: 'test_skip', raise_message: e.message})
ensure
  my_test.teardown
  my_test.clear_doubles
end
puts
print '  CalcTest#test_error '
begin
  my_test.setup
  my_test.test_error
rescue Picotest::Skip => e
  my_test.report_skip({method: 'test_error', reason: e.message})
rescue => e
  my_test.report_exception({method: 'test_error', raise_message: e.message})
ensure
  my_test.teardown
  my_test.clear_doubles
end
puts
puts "----"
puts JSON.generate(my_test.result)
r = my_test.result
$LED = r["success_count"] * 16 + r["failures"].size
