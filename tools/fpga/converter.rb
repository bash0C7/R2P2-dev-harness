# .mrb -> ROM の変換器を CRuby から読み込む (参照インタプリタやテストが使う)。
#
# 変換器の本体 (FILES と MAIN) は mruby ソースコードで、PicoRuby と CRuby の共通部分で書いてある。rake は
# 書いた順に1つの .rb につなぎ、PicoRuby の host VM (build_config/fpga-tools.rb、`rake fpga:picoruby`) で
# `picoruby converter.rb ...` として走らせる (PicoRuby に require が無い)。
# - `picoruby a.rb,b.rb` と `,` でつなぐと file ごとに別の task になり、CPU が混んでいると後の file が前の file の定義
#   (定数など) より先に走ることがある (vendor/picoruby の picoruby.c の [tasks])
# - mrbc で .mrb にして渡すと、picoruby.c が終わりに mrb_read_irep の irep を mrc_irep_free で解放してヒープを壊す
#   (debug 無しの VM は SEGV。debug の VM は est_free の検査が黙って飛ばすので見えない)
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

  # 変換器を走らせる host の picoruby (debug 無し。rake fpga:picoruby が build する)
  PICORUBY_DIR = File.expand_path("../../build/picoruby-fpga", DIR)

  def self.default_picoruby
    ENV["PICORUBY"] || File.join(PICORUBY_DIR, "bin", "picoruby")
  end

  @program = nil
  @program_lock = Mutex.new

  # 変換器を書いた順に1つの .rb に (process ごとに1回。thread から同時に呼んでよい)。file の境目に元の名前を書く
  def self.program_rb
    @program_lock.synchronize do
      @program ||= begin
        dir = Dir.mktmpdir("fpga-converter")
        at_exit { FileUtils.rm_rf(dir) }
        out = File.join(dir, "converter.rb")
        File.write(out, sources.map { |src| "# ---- #{File.basename(src)}\n#{File.read(src)}" }.join("\n"))
        out
      end
    end
  end

  # PicoRuby の host VM で変換器を走らせ、hex と lst を書く。返り値は変換器の標準出力 ("ok N words, nregs M")
  def self.run(mrb, hex, lst, max_regs: nil, picoruby: default_picoruby)
    unless File.executable?(picoruby)
      raise Error, "picoruby not found at #{picoruby}. Run `rake fpga:picoruby`, or set PICORUBY="
    end
    args = [picoruby, program_rb, mrb, hex, lst]
    args << max_regs.to_s if max_regs
    out, err, st = Open3.capture3(*args)
    raise Error, (err.empty? ? out : err).strip unless st.success?
    out.strip
  end

  def self.read_hex(path)
    File.readlines(path, chomp: true).map(&:strip).reject(&:empty?).map { |l| l.to_i(16) }
  end
end
