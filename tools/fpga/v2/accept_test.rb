require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "accept"

# 合否の物差し (計画 S1) の test: scope.tsv の守り、結果の読み方、shim の _str_match? (driver.c の写し) が CRuby の File.fnmatch と同じこと
class FpgaV2AcceptTest < Minitest::Test
  A = FpgaV2::Accept

  def picoruby = FpgaConverter.default_picoruby

  def test_committed_scope_rows_are_justified
    assert_equal [], A.check_scope
  end

  def test_scope_row_without_its_sign_is_rejected
    rows = [{ file: "array", name: "Array#push", code: "D31" }]
    assert_match(/no sign of D31/, A.check_scope(rows).first.to_s)
    rows = [{ file: "array", name: "Array#push", code: "D99" }]
    assert_match(/unknown reason/, A.check_scope(rows).first.to_s)
  end

  def test_in_scope_minimum_is_recorded
    assert_operator File.read(A::IN_SCOPE_MIN).to_i, :>, 0
  end

  def test_parse_numbers_repeated_names
    out = "..\n@@ OK \"a\"\n@@ KO \"a\"\n@@ Crash \"b \\\"q\\\"\"\n"
    assert_equal [["a", "a", "OK"], ["a #2", "a", "KO"], ["b \"q\"", "b \"q\"", "Crash"]], A.parse(out)
  end

  def test_body_finds_escaped_quote_names
    body = A.body("module", "Module#method_defined? with inherit false reports only the module's own methods")
    assert_match(/TestNotImplement/, body)
  end

  # assert.rb は RUBY_ENGINE が mruby でない時、_str_match? を File.fnmatch?(pat, str, FNM_EXTGLOB | FNM_DOTMATCH) で定義する。
  # shim の写しが host の PicoRuby の上でそれと同じ答えを出すこと
  def test_shim_str_match_agrees_with_fnmatch
    skip "host の picoruby が無い (rake fpga:picoruby)" unless File.executable?(picoruby)
    cases = [
      ["*", "abc"], ["a*c", "abc"], ["a*c", "abd"], ["a?c", "abc"], ["a?c", "ac"], ["[a-c]x", "bx"], ["[!a-c]x", "bx"],
      ["[^a-c]x", "dx"], ["a\\*", "a*"], ["a\\*", "ab"], ["{foo,bar}", "bar"], ["x{a,b{c,d}}y", "xbdy"], ["x{a,b}y", "xcy"],
      ["*.rb", ".hidden.rb"], ["**", ""], ["", ""], ["a*", ""], ["{a,}", ""], ["[]]", "]"], ["a[", "a["],
      ["*error*", "undefined method 'foo' for nil (NoMethodError)"], ["*[0-9]*", "abc9"]
    ]
    Dir.mktmpdir do |dir|
      prog = File.join(dir, "m.rb")
      File.write(prog, cases.map { |p, s| "puts _str_match?(#{p.inspect}, #{s.inspect})\n" }.join)
      out, st = Open3.capture2e(picoruby, "-r", File.join(A::ACCEPT_DIR, "shim.rb"), prog)
      assert st.success?, out
      want = cases.map { |p, s| File.fnmatch?(p, s, File::FNM_EXTGLOB | File::FNM_DOTMATCH).to_s }
      assert_equal want, out.lines.map(&:chomp)
    end
  end

  # host の走らせ方は -r で順に読むので、何度走らせても同じ (「a,b,c」の形は並行の task で順が決まらなかった)
  def test_host_run_is_deterministic
    skip "host の picoruby が無い (rake fpga:picoruby)" unless File.executable?(picoruby)
    a = A.host("array", picoruby: picoruby)
    b = A.host("array", picoruby: picoruby)
    assert_equal a, b
    assert_operator A.parse(a).size, :>, 50
  end
end
