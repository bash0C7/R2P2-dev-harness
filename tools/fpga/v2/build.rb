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

    # .rb (1つか複数) を mrbc で1つの .mrb に。debug は -g (irep の debug 情報、backtrace の file と line。
    # host の picoruby が .rb を読む時と同じ。mruby の mrblib と firmware は debug 情報無しで build する)
    def compile(sources, debug: true)
      Dir.mktmpdir do |dir|
        out = File.join(dir, "out.mrb")
        o, st = Open3.capture2e(mrbc, *(debug ? ["-g"] : []), "-o", out, *sources)
        raise Image::Error, "mrbc failed:\n#{o}" unless st.success?
        File.binread(out)
      end
    end

    def firmware = compile(firmware_sources, debug: false)

    # mruby の mrblib (mruby ソースコード、そのまま)。mruby の tasks/mrblib.rake と同じく名前の順に 1 つの .mrb に
    MRBLIB_DIR = File.join(ROOT, "vendor", "picoruby", "mrbgems", "picoruby-mruby", "lib", "mruby", "mrblib")
    # mruby の core の gem の mrblib (mrb_init_mrbgems の順、host の build の gem_init.c と同じ)。gem の C は firmware に写す。
    # IO と Dir と Task と Method の gem は、それぞれの C (と板のデバイス) を写す時に足す (計画 S5-7、S7)
    MRBLIB_GEMS_DIR = File.join(ROOT, "vendor", "picoruby", "mrbgems", "picoruby-mruby", "lib", "mruby", "mrbgems")
    MRBLIB_GEMS = %w[mruby-proc-ext mruby-toplevel-ext mruby-object-ext mruby-numeric-ext mruby-string-ext mruby-array-ext
                     mruby-hash-ext mruby-sprintf].freeze
    def mrblib_sources
      Dir[File.join(MRBLIB_DIR, "*.rb")].sort + MRBLIB_GEMS.flat_map { |g| Dir[File.join(MRBLIB_GEMS_DIR, g, "mrblib", "*.rb")].sort }
    end
    def mrblib = compile(mrblib_sources, debug: false)

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
