# .mrb -> ROM の変換器を CRuby から読み込む (参照インタプリタやテストが使う)。
#
# 変換器の本体 (FILES) は PicoRuby と CRuby の共通部分で書いてあり、rake は PicoRuby の host VM で
# `picoruby isa.rb,io_map.rb,rite.rb,rom.rb,mrb2rom.rb ...` として走らせる (PicoRuby に require が無いので
# `,` でつなぐ)。CRuby 側はここで同じ file を同じ順に読む。
module FpgaConverter
  FILES = %w[isa io_map rite rom].freeze
  MAIN  = "mrb2rom".freeze
  DIR   = __dir__

  # PicoRuby に渡す programfile (`,` でつないだ path)
  def self.picoruby_program
    (FILES + [MAIN]).map { |f| File.join(DIR, "#{f}.rb") }.join(",")
  end
end

FpgaConverter::FILES.each { |f| require_relative f }

module FpgaConverter
  class Error < StandardError; end

  def self.default_picoruby
    ENV["PICORUBY"] || File.expand_path("../../vendor/picoruby/bin/picoruby", DIR)
  end

  # PicoRuby の host VM で変換器を走らせ、hex と lst を書く。返り値は変換器の標準出力 ("ok N words, nregs M")
  def self.run(mrb, hex, lst, max_regs: nil, picoruby: default_picoruby)
    require "open3"
    unless File.executable?(picoruby)
      raise Error, "picoruby not found at #{picoruby}. Run `rake setup` and `rake test:host`, or set PICORUBY="
    end
    args = [picoruby, picoruby_program, mrb, hex, lst]
    args << max_regs.to_s if max_regs
    out, err, st = Open3.capture3(*args)
    raise Error, (err.empty? ? out : err).strip unless st.success?
    out.strip
  end

  def self.read_hex(path)
    File.readlines(path, chomp: true).map(&:strip).reject(&:empty?).map { |l| l.to_i(16) }
  end
end
