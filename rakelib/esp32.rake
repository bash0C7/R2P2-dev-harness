# ESP32 (M5Stack Chain DualKey) 向けのタスク。
#
# build/flash は vendor/R2P2-ESP32 (`rake esp32:setup` が clone する bash0C7/R2P2-ESP32、
# branch r2p2-esp32-btstack-integration, VM=mruby) の rake にそのまま委ねる。
# ESP-IDF は Mac に入れない。build / qemu_check / evq_* は Apple Container の中で回す
# (`rake "container:rake[esp32:build]"`、rakelib/container.rake と docs/spec.md §9)。
# upload/run/reboot はこの harness 自前の tools/esp32/ で picomodem
# プロトコルを直接話す。
require_relative "../tools/esp32/qemu_verdict"
require_relative "../tools/esp32/idf_target"

R2P2_ESP32_GIT = ENV["R2P2_ESP32_GIT"] || "https://github.com/bash0C7/R2P2-ESP32.git"
R2P2_ESP32_REF = ENV["R2P2_ESP32_REF"] || "r2p2-esp32-btstack-integration"

namespace :esp32 do
  VM = "mruby".freeze # PICORB_VMS[:picoruby] => :mruby in R2P2-ESP32's Rakefile

  desc "Clone R2P2-ESP32 into vendor/R2P2-ESP32 (env: R2P2_ESP32_GIT / R2P2_ESP32_REF); its picoruby submodule stays uninitialized"
  task :setup do
    dir = esp32_repo_dir
    if File.directory?(File.join(dir, ".git"))
      puts "#{dir} is already there."
    else
      # submodule は取らない。picoruby は container が ESP32_PICORUBY の tree を重ねる
      # (rakelib/container.rake)。取ると ESP32_PICORUBY の tree と別物の picoruby が並び、どちらで
      # build したかが分からなくなる。
      sh "git", "clone", "--branch", R2P2_ESP32_REF, R2P2_ESP32_GIT, dir
    end
  end

  desc "Build the R2P2-ESP32 firmware (mruby VM) and boot-check it under QEMU"
  task :build do
    require_esp32_repo!
    ensure_console_overlay!
    FileUtils.cd(esp32_repo_dir) do
      # After the overlay, which may delete sdkconfig: set-target regenerates
      # it from sdkconfig.defaults, overlay included.
      sdkconfig = File.exist?("sdkconfig") ? File.read("sdkconfig") : ""
      sh "idf.py set-target #{IdfTarget::TARGET}" unless IdfTarget.set?(sdkconfig)
      sh "rake picoruby:build"
      sh "bash scripts/qemu_boot_check.sh #{VM}"
    end
  end

  desc "Judge boot-loop (Core panic) under QEMU from the log; run before flashing (needs IDF env exported)"
  task :qemu_check do
    require_esp32_repo!
    ENV["QEMU_BOOT_TIMEOUT"] ||= "60"
    log_path = File.join(esp32_repo_dir, "qemu-boot-#{VM}.log")
    File.delete(log_path) if File.exist?(log_path)
    FileUtils.cd(esp32_repo_dir) do
      # exit is 1 for both panic and the "$> " timeout; the log decides.
      system("bash scripts/qemu_boot_check.sh #{VM}")
    end
    raise "#{log_path} was not produced" unless File.file?(log_path)
    result = QemuVerdict.judge(File.read(log_path))
    puts "[esp32:qemu_check] #{result.pass ? 'PASS' : 'FAIL'}: #{result.message}"
    exit 1 unless result.pass
  end

  desc "Flash the last build to the board via esptool"
  task :flash do
    with_board("esp32") do
      require_esp32_repo!
      FileUtils.cd(esp32_repo_dir) do
        sh "rake flash"
      end
    end
  end

  desc "Compile a local .rb to .mrb (HARNESS_SEND_RB=1: send source) and copy it over PicoModem (/home/app.mrb autostarts at boot)"
  task :upload, [:src, :dst] do |_t, args|
    with_board("esp32") do
      src = args[:src] or raise "usage: rake esp32:upload[<local .rb>,</home/name.rb>]"
      payload = prepare_payload(src, args[:dst], esp32_mrbc)
      esp32_device_tool "pmput.rb", payload.local, payload.remote
    end
  end

  desc "Run an app on the board and capture its log"
  task :run, [:app, :seconds] do |_t, args|
    with_board("esp32") do
      app = args[:app] or raise "usage: rake esp32:run[<local .rb>,<seconds>]"
      seconds = args[:seconds] || "20"
      payload = prepare_payload(app, nil, esp32_mrbc)
      esp32_device_tool "pmput.rb", payload.local, payload.remote
      esp32_device_tool "runapp.rb", payload.remote, seconds
    end
  end

  desc "Reset the board (RTS pulse) and wait for the shell"
  task :reboot do
    with_board("esp32") do
      esp32_device_tool "reset.rb"
    end
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
# PICORUBY_REPO/PICORUBY_REF in the top-level Rakefile. The default lives under
# vendor/ rather than next to the harness: a sibling path made every relative
# reference depend on where the harness happened to be cloned.
def esp32_repo_dir
  ENV["R2P2_ESP32_REPO"] || File.join(VENDOR_DIR, "R2P2-ESP32")
end

# firmware を build した picoruby の host mrbc。VM の版が実機と合う必要がある。
def esp32_mrbc
  File.join(esp32_repo_dir, "components", "picoruby-esp32", "picoruby", "build", "host", "bin", "mrbc")
end

def require_esp32_repo!
  dir = esp32_repo_dir
  unless File.directory?(dir)
    raise "R2P2-ESP32 not found at #{dir}. Run `rake esp32:setup`, " \
          "or set R2P2_ESP32_REPO=/path/to/R2P2-ESP32."
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
