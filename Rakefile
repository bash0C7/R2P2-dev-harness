require "fileutils"
require "digest"
require "shellwords"

HARNESS_ROOT  = __dir__
VENDOR_DIR    = File.join(HARNESS_ROOT, "vendor")
PICORUBY_SRC  = File.join(VENDOR_DIR, "picoruby")
PICORUBY_REPO = ENV["PICORUBY_REPO"] || "https://github.com/picoruby/picoruby.git"
PICORUBY_REF  = ENV["PICORUBY_REF"]  || "master"
BUILD_DIR     = File.join(HARNESS_ROOT, "build")

# ハーネスが持つ gem。build_config が gemdir: で指し、test:host がこの順で回す。
HARNESS_GEMS = %w[
  picoruby-usb-peripheral
  picoruby-usb-peripheral-cdc-midi
].freeze

# ホストで build するのに要る submodule だけ。pico-sdk は rp2040 の話なので入れない
# (`rake rp2040:setup` が別に取る)。
HOST_SUBMODULES = %w[
  mrbgems/picoruby-mruby/lib/mruby
  mrbgems/mruby-compiler
  mrbgems/mruby-bin-mrbc
  mrbgems/picoruby-machine/lib/estalloc
  mrbgems/picoruby-regexp_light/lib/regex_light
  mrbgems/picoruby-littlefs/lib/littlefs
].freeze

def vendor_ready?
  File.directory?(File.join(PICORUBY_SRC, ".git"))
end

def require_vendor!
  return if vendor_ready?
  raise "vendor/picoruby is not there. Run `rake setup` first."
end

# vendor の中で rake を回す。`rake` が PATH に無い環境 (rbenv の shim が
# 効いていない CI など) でも通るように、ruby 経由で叩く。
def vendor_rake(env, *args)
  require_vendor!
  rake = Gem.bin_path("rake", "rake") rescue nil
  command = rake ? "#{RbConfig.ruby.shellescape} #{rake.shellescape}" : "rake"
  FileUtils.cd(PICORUBY_SRC) do
    sh env, "#{command} #{args.map(&:shellescape).join(' ')}"
  end
end

task default: ["test:host"]
