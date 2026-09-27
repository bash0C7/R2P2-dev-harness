# v2 の firmware と起動の像を作り、参照で走らせる道具 (rake fpga:v2:run、テスト)。
require "open3"
require "tmpdir"
require_relative "image"
require_relative "ref"
require_relative "../converter"

module FpgaV2
  module Build
    ROOT = File.expand_path("../../..", __dir__)
    FIRMWARE_DIR = File.join(ROOT, "fpga", "firmware")

    module_function

    def mrbc = FpgaConverter.default_picoruby.sub(/picoruby\z/, "mrbc")

    def firmware_sources = Dir[File.join(FIRMWARE_DIR, "*.rb")].sort

    # .rb (1つか複数) を mrbc で1つの .mrb に
    def compile(sources)
      Dir.mktmpdir do |dir|
        out = File.join(dir, "out.mrb")
        o, st = Open3.capture2e(mrbc, "-o", out, *sources)
        raise Image::Error, "mrbc failed:\n#{o}" unless st.success?
        File.binread(out)
      end
    end

    def firmware = compile(firmware_sources)

    # mruby の mrblib (mruby ソースコード、そのまま)。mruby の tasks/mrblib.rake と同じく名前の順に 1 つの .mrb に
    MRBLIB_DIR = File.join(ROOT, "vendor", "picoruby", "mrbgems", "picoruby-mruby", "lib", "mruby", "mrblib")
    def mrblib_sources = Dir[File.join(MRBLIB_DIR, "*.rb")].sort
    def mrblib = compile(mrblib_sources)

    def image(programs)
      Image.new(firmware: firmware, mrblib: mrblib, programs: programs).build
    end

    # プログラム (.rb の中身) を走らせてコンソールの出力を返す
    def run_source(src, max_steps: 10_000_000)
      Dir.mktmpdir do |dir|
        rb = File.join(dir, "prog.rb")
        File.write(rb, src)
        ref = Ref.new(image([compile([rb])]), max_steps: max_steps)
        [ref.run, ref]
      end
    end
  end
end
