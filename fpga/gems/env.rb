# FPGA 版の env gem の C の所 (PicoRuby の picoruby-env の src/mruby/env.c)。Ruby の所 (ENVClass#each、ENV = ENVClass.new) は
# PicoRuby の mrblib/env.rb をそのまま使う。板に環境変数は無いので空の Hash から始める (RP2040 の port と同じ)
class ENVClass
  def initialize
    @hash = {}
  end

  def []=(key, value)
    raise TypeError, "no implicit conversion into String" unless key.is_a?(String) && value.is_a?(String)
    @hash[key] = value
  end

  def [](key)
    raise TypeError, "no implicit conversion into String" unless key.is_a?(String)
    @hash[key]
  end

  def delete(key)
    raise TypeError, "no implicit conversion into String" unless key.is_a?(String)
    @hash.delete(key)
  end

  def _hash
    @hash
  end
end
