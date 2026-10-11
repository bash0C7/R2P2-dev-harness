# FPGA 版の File。ボードにはファイルシステムが無い (範囲外。docs/spec.md §10) ので、開こうとすると NotImplementedError
# (PSG::Driver#play_prs などが名前を使う)
class File
  def self.open(*_args)
    raise NotImplementedError, "no file system on the FPGA core"
  end

  def self.exist?(_path)
    false
  end

  def read(*_args)
    raise NotImplementedError, "no file system on the FPGA core"
  end

  def seek(*_args)
    raise NotImplementedError, "no file system on the FPGA core"
  end

  def close
    nil
  end
end
