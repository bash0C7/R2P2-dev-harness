namespace :test do
  desc "Run the harness gems' picotest on the host (no board needed)"
  task :host do
    require_vendor!
    ensure_host_vm_current!

    require picotest_path
    ENV["RUBY"] = host_vm_path
    raise "host VM not found at #{host_vm_path}" unless File.executable?(host_vm_path)

    failed = []
    HARNESS_GEMS.each do |name|
      gem_dir = File.join(HARNESS_ROOT, "gems", name)
      test_dir = File.join(gem_dir, "test")
      next unless Dir.exist?(test_dir)

      puts "\n=== #{name} ==="
      runner = Picotest::Runner.new(
        test_dir,
        tmpdir: File.join(BUILD_DIR, "test"),
        require_name: require_name_of(name),
        load_path: gem_dir
      )
      failed << name unless runner.run == 0
    end

    unless failed.empty?
      raise "picotest failed: #{failed.join(', ')}"
    end
  end
end

def host_vm_path
  File.join(PICORUBY_SRC, "build", "host", "bin", "picoruby")
end

def picotest_path
  File.join(PICORUBY_SRC, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
end

def host_test_config
  File.join(HARNESS_ROOT, "build_config", "host-test.rb")
end

# upstream の gem は mrbgems/ に居るので upstream の test task で回る。
# ハーネスの gem は gemdir: で外から差しているぶん collect_gems が拾わないので、
# build と runner はこちらで持つ。build_config は upstream のものを load し直す
# だけなので、複製にはなっていない。
def build_host_vm
  FileUtils.mkdir_p File.join(BUILD_DIR, "test")
  env = { "PICORB_DEBUG" => "1", "MRUBY_CONFIG" => host_test_config }
  vendor_rake(env, "all")
end

# `vendor/picoruby/build/host/` は vendor/picoruby の中の共有ディレクトリ。
# `vendor/picoruby` の中で upstream 自身の rake タスクを直接叩くと
# (例: `rake test:gems:picoruby[<gem>]` で依存を検証するときなど)、
# そちらは自分専用の一時 build_config で `rake clean` してから同じ
# `build/host/` を作り直すことがあり、このharnessの gem を含まない別物の VM に
# 静かに差し替わる。`SKIP_BUILD=1` は「テストだけ直したので rebuild を省きたい」
# という意思表示であって、外部要因での差し替えまで黙って信用してよいという
# 意味ではないので、rp2040.rake の firmware_stamp と同じ考え方で
# 「今の入力に対して本当に有効か」を都度確認し、ずれていれば SKIP_BUILD が
# 立っていても作り直す。
HOST_TEST_INPUT_GLOBS = %w[
  mrbgem.rake
  mrblib/**/*.rb
  src/**/*
  ports/**/*
  include/**/*
].freeze

def host_test_stamp
  sha = File.directory?(File.join(PICORUBY_SRC, ".git")) ? `git -C #{PICORUBY_SRC.shellescape} rev-parse HEAD`.strip : ""
  inputs = [sha]
  SUBMODULE_PINS.each_key do |path|
    inputs << `git -C #{File.join(PICORUBY_SRC, path).shellescape} rev-parse HEAD 2>/dev/null`.strip
  end
  inputs << Digest::SHA256.file(host_test_config).hexdigest
  HARNESS_GEMS.each do |name|
    gem_dir = File.join(HARNESS_ROOT, "gems", name)
    HOST_TEST_INPUT_GLOBS.each do |glob|
      Dir[File.join(gem_dir, glob)].sort.each do |path|
        next unless File.file?(path)
        inputs << path.sub("#{HARNESS_ROOT}/", "")
        inputs << Digest::SHA256.file(path).hexdigest
      end
    end
  end
  Digest::SHA256.hexdigest(inputs.join("\n"))
end

def host_test_stamp_path
  File.join(PICORUBY_SRC, "build", "host", ".harness-test-stamp")
end

def ensure_host_vm_current!
  want = host_test_stamp
  stamp = host_test_stamp_path
  current = File.file?(stamp) ? File.read(stamp).strip : nil

  if ENV["SKIP_BUILD"]
    return if current == want && File.executable?(host_vm_path)
    puts "build/host stamp mismatch despite SKIP_BUILD (something else rebuilt " \
         "vendor/picoruby/build/host/ since the last rake test:host run) — rebuilding anyway"
  end

  build_host_vm
  File.write(stamp, want)
end

def require_name_of(gem_name)
  rake_file = File.join(HARNESS_ROOT, "gems", gem_name, "mrbgem.rake")
  found = File.read(rake_file)[/require_name\s*=\s*['"]([^'"]+)['"]/, 1]
  found || gem_name.sub(/\Apicoruby-/, "")
end

namespace :test do
  desc "Compile every example with picoruby's own compiler (catches parser-level typos)"
  task :examples do
    require_vendor!
    mrbc = File.join(PICORUBY_SRC, "build", "host", "bin", "mrbc")
    unless File.executable?(mrbc)
      raise "mrbc is not built yet. Run `rake test:host` first (it builds the host tools)."
    end
    out_dir = File.join(BUILD_DIR, "examples")
    FileUtils.mkdir_p out_dir
    examples = Dir[File.join(HARNESS_ROOT, "examples", "**", "*.rb")].sort
    raise "no examples found" if examples.empty?
    examples.each do |path|
      rel = path.sub("#{HARNESS_ROOT}/", "")
      out = File.join(out_dir, File.basename(path, ".rb") + ".mrb")
      sh "#{mrbc.shellescape} -o #{out.shellescape} #{path.shellescape}"
      puts "ok #{rel}"
    end
  end
end
