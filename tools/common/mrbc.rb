# Decide what `upload` / `run` actually put on the board.
# A .rb sent as source is compiled by prism on the device, which eats heap and
# dies with NoMemoryError (measured on Chain DualKey), so a .rb is compiled
# here with the firmware's own mrbc and the .mrb is sent instead.
require "fileutils"
require "open3"

module Mrbc
  class Error < StandardError; end

  Payload = Struct.new(:local, :remote, keyword_init: true)

  module_function

  # src: local .rb or .mrb. remote: the device path the caller wants, or nil.
  # mrbc: path to the mrbc built from the firmware's picoruby.
  # raw_rb: true sends a .rb as-is (escape hatch, HARNESS_SEND_RB=1).
  # compile_fn: (mrbc, src, out) -> [ok, output], injected for tests.
  def prepare(src, remote:, mrbc:, out_dir:, raw_rb: false, compile_fn: method(:run_mrbc))
    ext = File.extname(src)
    remote ||= "/home/#{File.basename(src)}"
    return Payload.new(local: src, remote: remote) if raw_rb || ext == ".mrb"
    raise Error, "#{src}: expected a .rb or .mrb file" unless ext == ".rb"

    unless mrbc && File.executable?(mrbc)
      raise Error, "mrbc not found at #{mrbc.inspect}. Build the firmware's picoruby host " \
                   "first, or set MRBC=/path/to/mrbc (HARNESS_SEND_RB=1 sends the .rb as source)."
    end

    FileUtils.mkdir_p(out_dir)
    out = File.join(out_dir, File.basename(src, ".rb") + ".mrb")
    ok, output = compile_fn.call(mrbc, src, out)
    raise Error, "mrbc failed on #{src}:\n#{output}" unless ok && File.file?(out)

    Payload.new(local: out, remote: remote.sub(/\.rb\z/, ".mrb"))
  end

  def run_mrbc(mrbc, src, out)
    output, status = Open3.capture2e(mrbc, "-o", out, src)
    [status.success?, output]
  end
end
