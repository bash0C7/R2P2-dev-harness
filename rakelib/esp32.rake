# ESP32 (M5Stack Chain DualKey) 向けのタスク。
#
# build/flash は bash0C7/R2P2-ESP32 の sibling checkout (branch
# r2p2-esp32-btstack-integration, VM=mruby) にそのまま委ねる。ESP-IDF の
# インストール・保守はこの harness の責務にしない (docs/spec.md 参照)。
# upload/run/reboot はこの harness 自前の tools/esp32/ で picomodem
# プロトコルを直接話す。
namespace :esp32 do
  VM = "mruby".freeze # PICORB_VMS[:picoruby] => :mruby in R2P2-ESP32's Rakefile

  desc "Build the R2P2-ESP32 firmware (mruby VM) and boot-check it under QEMU"
  task :build do
    require_esp32_repo!
    ensure_console_overlay!
    FileUtils.cd(esp32_repo_dir) do
      sh "rake picoruby:build"
      sh "bash scripts/qemu_boot_check.sh #{VM}"
    end
  end

  desc "Flash the last build to the board via esptool"
  task :flash do
    require_esp32_repo!
    FileUtils.cd(esp32_repo_dir) do
      sh "rake flash"
    end
  end

  desc "Copy a local .rb onto the board over PicoModem (/home/app.rb autostarts at boot)"
  task :upload, [:src, :dst] do |_t, args|
    src = args[:src] or raise "usage: rake esp32:upload[<local .rb>,</home/name.rb>]"
    dst = args[:dst] || "/home/#{File.basename(src)}"
    esp32_device_tool "pmput.rb", src, dst
  end

  desc "Run an app on the board and capture its log"
  task :run, [:app, :seconds] do |_t, args|
    app = args[:app] or raise "usage: rake esp32:run[<local .rb>,<seconds>]"
    seconds = args[:seconds] || "20"
    remote = "/home/#{File.basename(app)}"
    esp32_device_tool "pmput.rb", app, remote
    esp32_device_tool "runapp.rb", remote, seconds
  end

  desc "Reset the board (RTS pulse) and wait for the shell"
  task :reboot do
    esp32_device_tool "reset.rb"
  end
end

namespace :test do
  desc "Run the plain-Ruby host tests for tools/common and tools/esp32 (no board needed)"
  task :esp32 do
    Dir[File.join(HARNESS_ROOT, "tools", "common", "*_test.rb"),
        File.join(HARNESS_ROOT, "tools", "esp32", "*_test.rb")].sort.each do |test_file|
      sh "#{RbConfig.ruby.shellescape} #{test_file.shellescape}"
    end
  end
end

# ENV override for a non-standard checkout location, same convention as
# PICORUBY_REPO/PICORUBY_REF in the top-level Rakefile.
def esp32_repo_dir
  ENV["R2P2_ESP32_REPO"] || File.expand_path("../R2P2-ESP32", HARNESS_ROOT)
end

def require_esp32_repo!
  dir = esp32_repo_dir
  unless File.directory?(dir)
    raise "R2P2-ESP32 not found at #{dir}. Clone bash0C7/R2P2-ESP32 as a sibling " \
          "of this repo, or set R2P2_ESP32_REPO=/path/to/R2P2-ESP32."
  end
end

def esp32_device_tool(name, *args)
  script = File.join(HARNESS_ROOT, "tools", "esp32", name)
  raise "#{script} is missing" unless File.file?(script)
  sh "#{RbConfig.ruby.shellescape} #{script.shellescape} #{args.map { |a| a.to_s.shellescape }.join(' ')}"
end

# vendor/R2P2-ESP32 is a fresh, disposable checkout (docs/spec.md §9) with no
# board-specific sdkconfig of its own — idf.py's console default (UART0) is
# unreachable on Chain DualKey, which has no UART0 breakout (Task 8). Ensure
# the harness's console overlay is present in its sdkconfig.defaults before
# every build, and drop any already-generated sdkconfig so idf.py re-derives
# it from the updated defaults instead of silently keeping the stale choice.
def ensure_console_overlay!
  overlay = File.read(File.join(HARNESS_ROOT, "build_config", "esp32-chain_dualkey.sdkconfig.defaults"))
  defaults_path = File.join(esp32_repo_dir, "sdkconfig.defaults")
  current = File.exist?(defaults_path) ? File.read(defaults_path) : ""
  return if current.include?("CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y")

  File.write(defaults_path, "#{current}\n#{overlay}")
  sdkconfig = File.join(esp32_repo_dir, "sdkconfig")
  if File.exist?(sdkconfig)
    puts "[esp32] console overlay applied to sdkconfig.defaults — removing stale sdkconfig"
    File.delete(sdkconfig)
  end
end
