desc "Fetch picoruby into vendor/picoruby (env: PICORUBY_REPO / PICORUBY_REF)"
task :setup do
  if vendor_ready?
    puts "vendor/picoruby is already there. `rake refresh` to re-fetch."
  else
    FileUtils.mkdir_p VENDOR_DIR
    sh "git clone --depth 1 --branch #{PICORUBY_REF.shellescape} #{PICORUBY_REPO.shellescape} #{PICORUBY_SRC.shellescape}"
  end
  Rake::Task["vendor:submodules"].invoke
  Rake::Task["vendor:overlay"].invoke
end

desc "Re-fetch PICORUBY_REF into the existing vendor/picoruby"
task :refresh do
  require_vendor!
  FileUtils.cd(PICORUBY_SRC) do
    # overlay は tracked file を書き換えている。checkout の前に戻さないと、
    # upstream がその file を変えた瞬間に
    # "local changes would be overwritten" で止まる。
    sh "git checkout -- #{OVERLAY_TARGET.shellescape}" if File.exist?(File.join(PICORUBY_SRC, OVERLAY_TARGET))
    sh "git fetch --depth 1 origin #{PICORUBY_REF.shellescape}"
    sh "git checkout --detach FETCH_HEAD"
  end
  Rake::Task["vendor:submodules"].invoke
  Rake::Task["vendor:overlay"].invoke
end

desc "Remove every build output (vendor/picoruby stays)"
task :clean do
  FileUtils.rm_rf BUILD_DIR
  if vendor_ready?
    FileUtils.rm_rf File.join(PICORUBY_SRC, "build")
  end
end

namespace :vendor do
  desc "Init the submodules a host build needs (pico-sdk is rp2040:setup's job)"
  task :submodules do
    require_vendor!
    FileUtils.cd(PICORUBY_SRC) do
      sh "git submodule update --init --depth 1 #{HOST_SUBMODULES.map(&:shellescape).join(' ')}"
    end
  end

  # vendor/picoruby は生成物。upstream の file を置き換えるのはここだけで、
  # 何を置き換えたかは必ずこの task に書く。
  #
  # upstream の r2p2 rake task は build_config の path を
  # "build_config/r2p2-<vm>-<board>.rb" と自分で決め打つので、ハーネスの
  # build_config をそのまま渡す口が無い。よって
  #
  #   - upstream の原本を *.upstream.rb へ退避し (初回だけ)
  #   - その名前の file を「ハーネスの build_config を load するだけ」の shim にする
  #
  # 中身はハーネス側 (build_config/rp2040-pico2_w.rb) に残るので、upstream の
  # 内容を複製することにはならない。`rake refresh` で毎回張り直す。
  desc "Point vendor's build_config at the harness build_config (generated shim)"
  task :overlay do
    require_vendor!
    original = File.join(PICORUBY_SRC, OVERLAY_TARGET)
    preserved = File.join(PICORUBY_SRC, OVERLAY_PRESERVED)

    unless File.exist?(original) || File.exist?(preserved)
      puts "vendor/picoruby has no #{OVERLAY_TARGET}. Skipping the overlay."
      next
    end

    # 毎回 HEAD の中身を取り直してから張り直す。「もう張ってある」で早戻りすると、
    # refresh で HEAD が動いたあと *.upstream.rb が前の commit のままになり、
    # build は古い build_config を読み続ける。静かに間違う類のやつ。
    FileUtils.cd(PICORUBY_SRC) do
      sh "git checkout -- #{OVERLAY_TARGET.shellescape}"
    end

    FileUtils.cp original, preserved
    File.write(original, <<~SHIM)
      #{OVERLAY_MARKER}. Do not edit; `rake setup` / `rake refresh` rewrite it.
      # The real content lives in the harness at build_config/rp2040-pico2_w.rb.
      # The upstream original for this commit was preserved next to this file as
      # #{File.basename(OVERLAY_PRESERVED)}.
      load "#{File.join(HARNESS_ROOT, 'build_config', 'rp2040-pico2_w.rb')}"
    SHIM
    puts "overlay written: #{original}"
  end
end
