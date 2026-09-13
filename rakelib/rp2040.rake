# Raspberry Pi Pico 2 W 向けのタスク。
#
# 本 repo の完了条件は実機まで通って green (docs/spec.md §5) なので、
# build 以外はまだ「無い」ことを明示的に言う。黙って通ったふりはしない。
namespace :rp2040 do
  BOARD = "pico2_w".freeze

  desc "Init the pico-sdk submodule (big; only needed for firmware builds)"
  task :setup do
    require_vendor!
    FileUtils.cd(PICORUBY_SRC) do
      sh "git submodule update --init --recursive mrbgems/picoruby-r2p2/lib/pico-sdk"
    end
  end

  desc "Build the R2P2 firmware for Pico 2 W with the harness gems (prod)"
  task :build do
    require_vendor!
    ensure_overlay!
    invalidate_stale_firmware_build
    with_firmware_patches { vendor_rake({}, "r2p2:picoruby:#{BOARD}:prod") }
    uf2 = latest_uf2
    raise "no .uf2 came out of the build" unless uf2
    File.write(firmware_stamp_path, firmware_stamp)
    puts "firmware: #{uf2}"
  end

  desc "Print the .uf2 the last build produced"
  task :firmware do
    uf2 = latest_uf2
    raise "no firmware built yet. Run `rake rp2040:build`." unless uf2
    puts uf2
  end

  desc "Say whether the last firmware build is still good for the current inputs"
  task :stamp do
    want = firmware_stamp
    have = File.file?(firmware_stamp_path) ? File.read(firmware_stamp_path).strip : nil
    puts "inputs: #{want}"
    puts "built : #{have || '(never built)'}"
    puts(have == want ? "up to date" : "stale — the next build wipes build/ and starts over")
  end

  desc "Flash the firmware; a running board is dropped into BOOTSEL without the button (unverified)"
  task :flash do
    uf2 = latest_uf2
    raise "no firmware built yet. Run `rake rp2040:build`." unless uf2
    require_picotool!
    enter_bootsel!
    # picotool は mount を待つ。/Volumes/RP2350 への cp は mount 完了前に走ると
    # Device not configured で落ちる。ボリュームは見えているのに、である。
    sh "picotool load -x #{uf2.shellescape}"
    wait_until(90) { shell_answers? } or raise "flashed, but the R2P2 shell never answered"
  end

  desc "Copy a local .rb onto the board over PicoModem (unverified)"
  task :upload, [:src, :dst] do |_t, args|
    src = args[:src] or raise "usage: rake rp2040:upload[<local .rb>,</home/name.rb>]"
    dst = args[:dst] || "/home/#{File.basename(src)}"
    device_tool "pmput.rb", src, dst
  end

  desc "Run an app on the board and capture its log (unverified)"
  task :run, [:app, :seconds] do |_t, args|
    app = args[:app] or raise "usage: rake rp2040:run[<local .rb>,<seconds>]"
    seconds = args[:seconds] || "20"
    remote = "/home/#{File.basename(app)}"
    device_tool "pmput.rb", app, remote
    device_tool "runapp.rb", remote, seconds
  end

  desc "Reboot the board (unverified)"
  task :reboot do
    # R2P2 shell は入力を Ruby として評価しないので、プロンプトに Machine.reboot と
    # 打っても何も起きない。script を置いて実行する。
    device_tool "pmput.rb", File.join(HARNESS_ROOT, "tools", "pico2w", "reboot_app.rb"), "/home/reboot.rb"
    # 実行中に CDC が落ちるので ENXIO が出る。正常。
    device_tool "rsh.rb", "/home/reboot.rb", "4"
  end

  desc "build -> flash -> run -> judge (not implemented yet)"
  task :verify do
    raise <<~MSG
      rake rp2040:verify is not implemented yet.

      build / flash / run は揃ったが、**判定が無い**。CDC-MIDI なら
      「Mac が MIDI デバイスとして列挙したか」「送った event を受け取れたか」
      「teardown のあとに stuck note が残っていないか」を Mac 側で見る必要がある
      (docs/spec.md §5)。その相手役はまだ書いていない。

      判定が無いまま verify が通ると、完了の線引きが消える。だから落とす。
    MSG
  end
end

# 実機を触る helper は tools/pico2w/ に居る。serialport gem と、
# USB 製品名からポートを引くための macOS の ioreg が要る。
# どれもまだ実機で検証していない (docs/handoff-to-mac.md)。
def device_tool(name, *args)
  script = File.join(HARNESS_ROOT, "tools", "pico2w", name)
  raise "#{script} is missing" unless File.file?(script)
  sh "#{RbConfig.ruby.shellescape} #{script.shellescape} #{args.map { |a| a.to_s.shellescape }.join(' ')}"
end

# 動作中の board を BOOTSEL へ落とす。firmware-patches/machine-usb-boot.patch が
# 足す Machine.usb_boot (ROM の rom_reset_usb_boot) を board 上の script から呼ぶ。
# picotool reboot -f -u は使えない: R2P2 は VID 0x16c0 で reset interface も無く、
# picotool は動作中の board を列挙すらしない。BOOTSEL 中は ROM なので見える。
#
# patch の無い firmware が載っている時 (初回、または patch 無しを焼いた後) は
# script が NoMethodError で終わるだけなので、人手の BOOTSEL へ回す。
def enter_bootsel!
  # 中断した run は board を BOOTSEL に置き去りにする。その時 shell は居ない。
  return if bootsel?
  if r2p2_ports.any?
    # wedge した board への serial open は macOS で返らないので、壁時計で切る。
    bounded_device_tool 60, "pmput.rb", File.join(HARNESS_ROOT, "tools", "pico2w", "usbboot_app.rb"), "/home/usbboot.rb"
    # 実行中に CDC が落ちるので失敗扱いで返ってくる。正常。
    bounded_device_tool 40, "rsh.rb", "/home/usbboot.rb", "5"
    return if wait_until(30) { bootsel? }
  end
  puts <<~ASK
    Put the board into BOOTSEL: unplug USB, hold BOOTSEL, plug in, release.
    (Needed only while the board runs firmware without Machine.usb_boot: the
     first flash, or after flashing a build without firmware-patches/.
     If the board is wedged (enumerated but silent), a replug is needed too.)
  ASK
  wait_until(300) { bootsel? } or raise "the board never reached BOOTSEL"
end

def bootsel?
  system("picotool info > /dev/null 2>&1")
end

# 小さい方が CDC0 = R2P2 shell。/dev/cu.usbmodem* の glob で選ばない
# (ESP32 が先に並び、開くだけでそちらがリセットされる)。
def r2p2_ports
  `ioreg -w 0 -r -n "R2P2" -l 2>/dev/null`.scan(/"IOCalloutDevice" = "([^"]+)"/).flatten.sort
end

def shell_answers?
  system("#{RbConfig.ruby.shellescape} #{File.join(HARNESS_ROOT, 'tools', 'pico2w', 'shell_ok.rb').shellescape} > /dev/null 2>&1")
end

def wait_until(seconds)
  deadline = Time.now + seconds
  until Time.now > deadline
    return true if yield
    sleep 1
  end
  false
end

# device_tool を tmo.rb 越しに回す。失敗しても raise せず真偽を返す。
def bounded_device_tool(seconds, name, *args)
  tools = File.join(HARNESS_ROOT, "tools", "pico2w")
  ruby = RbConfig.ruby.shellescape
  command = [ruby, File.join(tools, "tmo.rb").shellescape, seconds.to_s,
             ruby, File.join(tools, name).shellescape, *args.map { |a| a.to_s.shellescape }].join(" ")
  puts command
  system(command)
end

# firmware-patches/*.patch を vendor/picoruby に当てて build し、終わったら戻す。
# vendor は upstream の木なので patch を残さない。前の build が SIGKILL された等で
# 当たったまま残っていたら、当て直さずにそのまま使う。
def with_firmware_patches
  patches = Dir[File.join(HARNESS_ROOT, "firmware-patches", "*.patch")].sort
  applied = []
  FileUtils.cd(PICORUBY_SRC) do
    patches.each do |patch|
      unless system("git apply --reverse --check #{patch.shellescape} > /dev/null 2>&1")
        sh "git apply #{patch.shellescape}"
      end
      applied << patch
    end
  end
  yield
ensure
  FileUtils.cd(PICORUBY_SRC) do
    applied.reverse_each { |patch| sh "git apply --reverse #{patch.shellescape}" }
  end
end

def require_picotool!
  return if system("which picotool > /dev/null 2>&1")
  raise <<~MSG
    picotool is not on PATH.

    The firmware exposes no mass storage, so picotool is the only way to flash.
    `cp` to /Volumes/RP2350 is not a substitute.
  MSG
end

def firmware_build_dir
  File.join(PICORUBY_SRC, "build", "r2p2", "picoruby", "pico2_w", "prod")
end

def latest_uf2
  Dir[File.join(firmware_build_dir, "*.uf2")].max_by { |f| File.mtime(f) }
end

def ensure_overlay!
  shim = File.join(PICORUBY_SRC, OVERLAY_TARGET)
  return if File.exist?(shim) && File.read(shim).start_with?(OVERLAY_MARKER)
  Rake::Task["vendor:overlay"].invoke
end

# build/<name>/ の stale 化を止める。
#
# mruby の compile rule は .c の mtime しか見ないので、vendor/picoruby を
# 取得し直しても、build_config を変えても、既存の .o の方が新しければ何も
# 再 compile されない。build task は成功したと言いながら前の archive を stage する。
# 入力の digest を build dir に記録し、変わっていたら dir ごと捨てる。
# firmware に入るものだけを見る。test/ と sig/ は build に効かないので外す
# (外さないと、テストを1行直しただけで10分の full rebuild が走る)。
FIRMWARE_INPUT_GLOBS = %w[
  mrbgem.rake
  mrblib/**/*.rb
  src/**/*
  ports/**/*
  include/**/*
].freeze

def firmware_stamp
  sha = File.directory?(File.join(PICORUBY_SRC, ".git")) ? `git -C #{PICORUBY_SRC.shellescape} rev-parse HEAD`.strip : ""
  inputs = [sha]
  inputs << Digest::SHA256.file(File.join(HARNESS_ROOT, "build_config", "rp2040-pico2_w.rb")).hexdigest
  Dir[File.join(HARNESS_ROOT, "firmware-patches", "*.patch")].sort.each do |patch|
    inputs << Digest::SHA256.file(patch).hexdigest
  end
  HARNESS_GEMS.each do |name|
    gem_dir = File.join(HARNESS_ROOT, "gems", name)
    FIRMWARE_INPUT_GLOBS.each do |glob|
      Dir[File.join(gem_dir, glob)].sort.each do |path|
        next unless File.file?(path)
        inputs << path.sub("#{HARNESS_ROOT}/", "")
        inputs << Digest::SHA256.file(path).hexdigest
      end
    end
  end
  Digest::SHA256.hexdigest(inputs.join("\n"))
end

def firmware_stamp_path
  File.join(firmware_build_dir, ".harness-build-stamp")
end

def invalidate_stale_firmware_build
  want = firmware_stamp
  stamp = firmware_stamp_path
  lib_dirs = [
    File.join(PICORUBY_SRC, "build", "r2p2-picoruby-pico2_w"),
    firmware_build_dir
  ]
  return unless File.directory?(firmware_build_dir)
  return if File.file?(stamp) && File.read(stamp).strip == want

  puts "picoruby, build_config or a harness gem changed since the last build — rebuilding from scratch"
  lib_dirs.each { |dir| FileUtils.rm_rf dir }
end
