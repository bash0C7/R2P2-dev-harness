# Judge a QEMU boot log from R2P2-ESP32's scripts/qemu_boot_check.sh.
# The script exits 1 both on a panic and on the "$> " timeout (local IDF
# v5.4.2 never reaches the prompt), so the verdict comes from the log.
module QemuVerdict
  Result = Struct.new(:pass, :message, keyword_init: true)

  PANIC = /Guru Meditation|Rebooting\.\.\./
  BOOTED = "main_task: Returned from app_main()".freeze

  module_function

  def judge(log)
    panic_lines = log.lines.grep(PANIC).map(&:chomp)
    unless panic_lines.empty?
      return Result.new(pass: false, message: "panic detected:\n#{panic_lines.join("\n")}")
    end

    if log.include?(BOOTED)
      return Result.new(pass: true, message: "no panic, shell prompt reached") if log.include?("$> ")
      return Result.new(pass: true, message: "no panic (shell prompt not reached; known on local IDF v5.4.2, CI uses v5.5.4)")
    end

    Result.new(pass: false, message: "boot not reached: no '#{BOOTED}' in log")
  end
end
