require "minitest/autorun"
require "tmpdir"
require_relative "mrbc"

class MrbcTest < Minitest::Test
  def with_dir
    Dir.mktmpdir { |d| yield d }
  end

  def fake_mrbc(dir)
    path = File.join(dir, "mrbc")
    File.write(path, "")
    File.chmod(0o755, path)
    path
  end

  def ok_compile
    ->(_mrbc, _src, out) { File.write(out, "RITE"); [true, ""] }
  end

  def test_rb_is_compiled_and_remote_becomes_mrb
    with_dir do |d|
      p = Mrbc.prepare("examples/a.rb", remote: nil, mrbc: fake_mrbc(d), out_dir: File.join(d, "out"), compile_fn: ok_compile)
      assert_equal File.join(d, "out", "a.mrb"), p.local
      assert_equal "/home/a.mrb", p.remote
    end
  end

  def test_explicit_remote_rb_suffix_is_swapped
    with_dir do |d|
      p = Mrbc.prepare("a.rb", remote: "/home/app.rb", mrbc: fake_mrbc(d), out_dir: d, compile_fn: ok_compile)
      assert_equal "/home/app.mrb", p.remote
    end
  end

  def test_mrb_passes_through
    p = Mrbc.prepare("a.mrb", remote: nil, mrbc: nil, out_dir: "unused")
    assert_equal "a.mrb", p.local
    assert_equal "/home/a.mrb", p.remote
  end

  def test_raw_rb_escape_hatch
    p = Mrbc.prepare("a.rb", remote: nil, mrbc: nil, out_dir: "unused", raw_rb: true)
    assert_equal "a.rb", p.local
    assert_equal "/home/a.rb", p.remote
  end

  def test_missing_mrbc_raises_instead_of_falling_back
    err = assert_raises(Mrbc::Error) { Mrbc.prepare("a.rb", remote: nil, mrbc: "/nonexistent/mrbc", out_dir: "x") }
    assert_includes err.message, "mrbc not found"
  end

  def test_compile_failure_raises_with_output
    with_dir do |d|
      failing = ->(*) { [false, "syntax error"] }
      err = assert_raises(Mrbc::Error) { Mrbc.prepare("a.rb", remote: nil, mrbc: fake_mrbc(d), out_dir: d, compile_fn: failing) }
      assert_includes err.message, "syntax error"
    end
  end

  def test_other_extension_rejected
    assert_raises(Mrbc::Error) { Mrbc.prepare("a.txt", remote: nil, mrbc: nil, out_dir: "x") }
  end
end
