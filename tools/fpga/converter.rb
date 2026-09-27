# .mrb -> ROM の変換器を CRuby から読み込む (参照インタプリタやテストが使う)。
#
# 変換器の本体 (FILES と MAIN) は mruby ソースコードで、PicoRuby と CRuby の共通部分で書いてある。rake は
# mrbc で1つの .mrb にまとめ (書いた順に1つの irep になる)、PicoRuby の host VM で `picoruby converter.mrb ...` として走らせる
# (PicoRuby に require が無い)。`picoruby a.rb,b.rb` と `,` でつなぐと file ごとに別の task になり、CPU が混んでいると後の file が
# 前の file の定義 (定数など) より先に走ることがあるので使わない (vendor/picoruby の picoruby.c の [tasks])。
# CRuby 側はここで同じ file を同じ順に読む。
require "open3"
require "tmpdir"
require "fileutils"

module FpgaConverter
  FILES = %w[isa io_map rite rom].freeze
  MAIN  = "mrb2rom".freeze
  DIR   = __dir__

  def self.sources
    (FILES + [MAIN]).map { |f| File.join(DIR, "#{f}.rb") }
  end
end

FpgaConverter::FILES.each { |f| require_relative f }

module FpgaConverter
  class Error < StandardError; end

  def self.default_picoruby
    ENV["PICORUBY"] || File.expand_path("../../vendor/picoruby/bin/picoruby", DIR)
  end

  @program = {}
  @program_lock = Mutex.new

  # 変換器を1つの .mrb に (process ごと・mrbc ごとに1回。thread から同時に呼んでよい)
  def self.program_mrb(mrbc)
    @program_lock.synchronize do
      @program[mrbc] ||= begin
        raise Error, "mrbc not found at #{mrbc}. Run `rake setup` and `rake test:host`, or set PICORUBY=" unless File.executable?(mrbc)
        dir = Dir.mktmpdir("fpga-converter")
        at_exit { FileUtils.rm_rf(dir) }
        out = File.join(dir, "converter.mrb")
        _o, err, st = Open3.capture3(mrbc, "-g", "-o", out, *sources)
        raise Error, "mrbc failed on the converter: #{err.strip}" unless st.success?
        out
      end
    end
  end

  # PicoRuby の host VM で変換器を走らせ、hex と lst を書く。返り値は変換器の標準出力 ("ok N words, nregs M")
  # mrbc は picoruby の隣のもの
  def self.run(mrb, hex, lst, max_regs: nil, picoruby: default_picoruby, mrbc: File.join(File.dirname(picoruby), "mrbc"))
    unless File.executable?(picoruby)
      raise Error, "picoruby not found at #{picoruby}. Run `rake setup` and `rake test:host`, or set PICORUBY="
    end
    args = [picoruby, program_mrb(mrbc), mrb, hex, lst]
    args << max_regs.to_s if max_regs
    out, err, st = Open3.capture3(*args)
    raise Error, (err.empty? ? out : err).strip unless st.success?
    out.strip
  end

  def self.read_hex(path)
    File.readlines(path, chomp: true).map(&:strip).reject(&:empty?).map { |l| l.to_i(16) }
  end
end
