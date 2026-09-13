namespace :test do
  desc "Run the harness gems' picotest on the host (no board needed)"
  task :host do
    require_vendor!
    build_host_vm unless ENV["SKIP_BUILD"]

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

def require_name_of(gem_name)
  rake_file = File.join(HARNESS_ROOT, "gems", gem_name, "mrbgem.rake")
  found = File.read(rake_file)[/require_name\s*=\s*['"]([^'"]+)['"]/, 1]
  found || gem_name.sub(/\Apicoruby-/, "")
end
