# Apple Container (`container` CLI) の中で build と QEMU を回すタスク。
#
# Mac に ESP-IDF も arm-none-eabi も入れない (docs/spec.md §9)。base image (espressif/idf:v5.5.4) から
# 常駐コンテナ r2p2-dev-harness を 1 つ作り、container/provision.sh で足りないパッケージを一度だけ入れ、
# 各タスクは `container exec` で走らせる。派生 image を build しない理由は tools/container/run_args.rb。
# argv の組み立ては tools/container/run_args.rb にあり、`rake test:container` で確かめる。
# 実機を触るタスク (flash / upload / run / reboot) はホストのまま。container から serial は見えない。
require "json"
require "open3"
require_relative "../tools/container/run_args"
require_relative "../tools/container/picoruby_tree"

CONTAINER_DIR = File.join(HARNESS_ROOT, "container")
CONTAINER_CACHE = File.join(HARNESS_ROOT, "tmp", "container")
CONTAINER_APP_ROOT = File.expand_path("~/Library/Application Support/com.apple.container")
CONTAINER_CREATED = File.join(CONTAINER_CACHE, "create.argv.json")
# base image の Ruby は 3.2。upstream picoruby の CI と揃えたいときは container:ruby で build し、
# CONTAINER_RUBY=<version> を付けて exec する (container/ruby.sh)。
CONTAINER_DEFAULT_RUBY = "4.0.1".freeze
# コンテナの形 (mount と資源) を決める環境変数。どれかを明示したときだけ作り直しを考える。
CONTAINER_SHAPE_ENV = %w[ESP32_PICORUBY R2P2_ESP32_REPO CONTAINER_CPUS CONTAINER_MEMORY].freeze

# image は圧縮 blob (4.4 GB) と展開済み snapshot (実測 9 GB) の両方で持たれる。取得中は OCI の
# tar も一時的に置く。足りない disk に入れると Mac 全体が詰まるので、入れる前に止める。
CONTAINER_MIN_FREE_GB = Integer(ENV["CONTAINER_MIN_FREE_GB"] || 20)

namespace :container do
  # `container image pull` はこの Mac で 2 回とも 3 GB の layer の途中で止まった (速度 0 のまま
  # 10 分以上、再試行は最初から)。blob ごとに curl で途中から再開できる取得にして、OCI layout を
  # tar にまとめて load する。
  desc "Fetch #{ContainerRun::IMAGE} (linux/arm64) blob by blob with resumable curl and load it"
  task :image do
    next puts("#{ContainerRun::IMAGE} is already loaded.") if container_image_present?

    require_container_disk!
    repo, tag = ContainerRun::IMAGE.delete_prefix("docker.io/").split(":", 2)
    layout = File.join(CONTAINER_CACHE, "oci", tag)
    tarball = "#{layout}.tar"
    sh "bash", File.join(HARNESS_ROOT, "tools", "container", "fetch_oci.sh"), repo, tag, "arm64", layout
    # macOS の tar は xattr を AppleDouble (._*) として混ぜるので止める
    sh({ "COPYFILE_DISABLE" => "1" }, "tar", "--no-mac-metadata", "--no-xattrs",
       "-cf", tarball, "-C", layout, "oci-layout", "index.json", "blobs")
    rm_rf layout
    sh "container", "image", "load", "-i", tarball
    rm_f tarball
    raise "#{ContainerRun::IMAGE} is still missing after the load" unless container_image_present?
  end

  desc "Create (or reuse) the dev container #{ContainerRun::NAME}; ESP32_PICORUBY=<picoruby tree> fills R2P2-ESP32's submodule slot"
  task :up do
    container_up
  end

  desc "Re-run container/provision.sh as root on the existing dev container (after editing it)"
  task :provision do
    container_up
    container_provision
  end

  desc "Stop the dev container to give its memory back (kept with its provision; the next container:* starts it)"
  task :stop do
    sh "container", "stop", ContainerRun::NAME if container_state == "running"
  end

  desc "Remove the dev container (the image and everything under tmp/container stay)"
  task :down do
    sh "container", "delete", "--force", ContainerRun::NAME if container_state
    rm_f CONTAINER_CREATED
  end

  desc "Interactive shell in the dev container"
  task :shell do
    container_exec("bash", tty: true)
  end

  desc "Run CMD in the dev container (DIR= sets the working dir, harness-relative or absolute)"
  task :exec do
    command = ENV["CMD"] or raise "usage: CMD='...' [DIR=...] rake container:exec"
    container_exec(command, workdir: ENV["DIR"])
  end

  desc "Build Ruby <version> (default #{CONTAINER_DEFAULT_RUBY}, upstream picoruby's CI) into tmp/container/ruby/<version>; use it with CONTAINER_RUBY=<version>"
  task :ruby, [:version] do |_t, args|
    version = args[:version] || CONTAINER_DEFAULT_RUBY
    # CONTAINER_RUBY が立っていると、まだ無い Ruby を探して container_exec が止まる
    ENV.delete("CONTAINER_RUBY")
    container_exec("bash #{File.join(CONTAINER_DIR, 'ruby.sh').shellescape} #{version.shellescape}")
  end

  desc "Run a harness rake task in the dev container, e.g. rake \"container:rake[esp32:evq_green]\""
  task :rake, [:task] do |_t, args|
    name = args[:task] or raise "usage: rake \"container:rake[<task>]\""
    require_esp32_slot_filled! if name.start_with?("esp32:")
    container_exec("rake #{name.shellescape}")
  end
end

namespace :test do
  desc "Run the plain-Ruby host tests for tools/container (no container needed)"
  task :container do
    Dir[File.join(HARNESS_ROOT, "tools", "container", "*_test.rb")].sort.each do |test_file|
      sh "#{RbConfig.ruby.shellescape} #{test_file.shellescape}"
    end
  end
end

# mount は作るときにしか決められない。作ったときの argv を保存し、今の入力 (ESP32_PICORUBY など)
# から組んだ argv と違えば作り直す。中身は全部 mount 側にあるので、作り直しで失うのは provision だけ。
def container_up
  Rake::Task["container:image"].invoke
  tree = container_env("ESP32_PICORUBY")
  if tree
    unless File.directory?(esp32_repo_dir)
      raise "ESP32_PICORUBY is set but #{esp32_repo_dir} is missing. Run `rake esp32:setup` first."
    end
    tree, git_dir = require_picoruby_tree!(File.expand_path(tree, HARNESS_ROOT))
  end

  argv = ContainerRun.create_argv(
    harness_root: HARNESS_ROOT, uid: Process.uid, gid: Process.gid,
    esp32_repo: esp32_repo_dir, esp32_picoruby: tree, picoruby_git_dir: git_dir,
    cpus: container_env("CONTAINER_CPUS") || "8", memory: container_env("CONTAINER_MEMORY") || "8G"
  )
  state = container_state
  saved = File.exist?(CONTAINER_CREATED) && JSON.parse(File.read(CONTAINER_CREATED))
  # 何も指定しなければ、今あるコンテナをそのまま使う。ESP32_PICORUBY を付け忘れただけで
  # 作り直すと、provision (数分と数百 MB の取得) をやり直すうえに、重ねていた tree が外れる。
  explicit = CONTAINER_SHAPE_ENV.any? { |key| container_env(key) }
  if state && saved && (!explicit || saved == argv)
    require_saved_mounts!(saved)
    sh "container", "start", ContainerRun::NAME unless state == "running"
    return
  end

  puts "[container] (re)creating #{ContainerRun::NAME}: its mounts or resources changed" if state
  sh "container", "delete", "--force", ContainerRun::NAME if state
  rm_f CONTAINER_CREATED
  %w[home bundle ccache].each { |dir| mkdir_p File.join(CONTAINER_CACHE, dir) }
  sh "container", "run", *argv
  container_provision
  File.write(CONTAINER_CREATED, JSON.generate(argv))
end

# 空の値は付けていないのと同じに扱う。`ESP32_PICORUBY=$TREE` で TREE が未設定だと "" になり、
# harness root を tree と取り違えてコンテナを作り直してしまう。
def container_env(key)
  value = ENV[key]
  value unless value.nil? || value.empty?
end

# 使い回すコンテナの mount 元が host に残っているか。picoruby の tree は Claude Code や cmux が
# 作って消すので、消えた tree を張ったまま回すと、空の slot の build が原因から遠い所で落ちる。
def require_saved_mounts!(argv)
  gone = ContainerRun.mounts_in(argv).map(&:first).uniq.reject { |source| File.directory?(source) }
  unless gone.empty?
    raise "#{ContainerRun::NAME} mounts #{gone.join(', ')}, which no longer exist.\n" \
          "Pass ESP32_PICORUBY=<tree> to recreate it, or run `rake container:down`."
  end
  tree = ContainerRun.slot_source(argv, File.expand_path(esp32_repo_dir, HARNESS_ROOT))
  puts "[container] picoruby tree on the slot: #{tree}" if tree
end

def container_provision
  sh "container", "exec", *ContainerRun.exec_argv(
    harness_root: HARNESS_ROOT, uid: Process.uid, gid: Process.gid, root: true, idf: false,
    command: "bash #{File.join(CONTAINER_DIR, 'provision.sh').shellescape}"
  )
end

def container_exec(command, tty: false, workdir: nil)
  container_up
  ruby_bin = nil
  if (version = ENV["CONTAINER_RUBY"])
    ruby_bin = File.join(CONTAINER_CACHE, "ruby", version, "bin")
    unless File.executable?(File.join(ruby_bin, "ruby"))
      raise "Ruby #{version} is not built yet. Run `rake \"container:ruby[#{version}]\"` first."
    end
  end
  # tree は realpath で張るので、host にある DIR も realpath にそろえる (symlink の名前は container に無い)
  if workdir
    path = File.expand_path(workdir, HARNESS_ROOT)
    workdir = File.realpath(path) if File.directory?(path)
  end
  sh "container", "exec", *ContainerRun.exec_argv(
    harness_root: HARNESS_ROOT, command: command, uid: Process.uid, gid: Process.gid,
    workdir: workdir, tty: tty, host_env: ENV.to_h, ruby_bin: ruby_bin
  )
end

# nil (無い) / "running" / "stopped"
def container_state
  out = `container inspect #{ContainerRun::NAME.shellescape} 2>/dev/null`
  return nil unless $?.success?

  JSON.parse(out).dig(0, "status", "state")
rescue JSON::ParserError
  nil
end

def container_image_present?
  system("container", "image", "inspect", ContainerRun::IMAGE, out: File::NULL, err: File::NULL)
end

def require_container_disk!
  probe = File.directory?(CONTAINER_APP_ROOT) ? CONTAINER_APP_ROOT : Dir.home
  available_kb = `df -k #{probe.shellescape}`.lines.last.split[3].to_i
  available_gb = available_kb / 1024 / 1024
  return if available_gb >= CONTAINER_MIN_FREE_GB

  raise <<~MSG
    Only #{available_gb} GB free where Apple Container keeps images (#{probe}).
    The image takes about 14 GB once loaded (4.4 GB of blobs + a 9 GB snapshot) and the OCI tarball needs 4.4 GB more while loading;
    #{CONTAINER_MIN_FREE_GB} GB is the floor (CONTAINER_MIN_FREE_GB).
  MSG
end

# R2P2-ESP32 の picoruby submodule は init しない。container の中で picoruby の tree を重ねる。
# 何も重ねずに esp32:* を回すと、空の dir を picoruby だと思って分かりにくく落ちる。
def require_esp32_slot_filled!
  return if container_env("ESP32_PICORUBY")

  slot = File.join(esp32_repo_dir, ContainerRun::SUBMODULE_SLOT)
  return if File.directory?(slot) && !Dir.empty?(slot)
  # 重ねた tree はコンテナの中にしか見えない。今あるコンテナが、host に残っている tree を重ねて
  # 作られていれば足りる。
  saved = container_state && File.exist?(CONTAINER_CREATED) && JSON.parse(File.read(CONTAINER_CREATED))
  source = saved && ContainerRun.slot_source(saved, File.expand_path(esp32_repo_dir, HARNESS_ROOT))
  return if source && File.directory?(source) && !Dir.empty?(source)

  raise <<~MSG
    #{slot} is empty. Point ESP32_PICORUBY at a picoruby tree (a clone or a worktree, made by any tool), e.g.
      ESP32_PICORUBY=~/ghq/github.com/bash0C7/picoruby rake "container:rake[esp32:evq_green]"
  MSG
end

# ESP32_PICORUBY の tree を確かめ、mount に使う tree の realpath と git の共通 dir を返す。
# tree は git の checkout に限る。submodule が init 済みかを git でしか確かめられないため。
def require_picoruby_tree!(tree)
  raise "ESP32_PICORUBY=#{tree} is not a directory." unless File.directory?(tree)

  out, err, status = Open3.capture3("git", "-C", tree, "rev-parse", "--show-toplevel", "--git-common-dir")
  top, common = out.lines.map(&:strip)
  raise "ESP32_PICORUBY=#{tree} is not a git checkout (a clone or a worktree):\n#{err}" unless status.success? && common
  # APFS は大文字小文字を区別しないので、パスの文字列ではなく同じ dir かで比べる
  raise "ESP32_PICORUBY=#{tree} is inside #{top}; point it at the top of the checkout." unless File.identical?(top, tree)
  unless File.directory?(File.join(tree, "mrbgems", "picoruby-mruby"))
    raise "ESP32_PICORUBY=#{tree} does not look like a picoruby tree (no mrbgems/picoruby-mruby)."
  end

  submodules, err, status = Open3.capture3("git", "-C", tree, "submodule", "status", "--recursive")
  raise "git submodule status failed in #{tree}:\n#{err}" unless status.success?

  missing = PicorubyTree.uninitialized_submodules(submodules)
  unless missing.empty?
    raise "#{tree} has uninitialized submodules (#{missing.join(', ')}).\n" \
          "Run `git -C #{tree.shellescape} submodule update --init --recursive` first."
  end
  # git の返す top (realpath、実際の大文字小文字) で張る。symlink の名前で張ると、付け替えても argv が
  # 変わらず古い tree を使い回すうえ、git が realpath 基準の相対パスで書く submodule の gitdir が
  # container の中で解けない。File.realpath は入力の大文字小文字を残すので使わない。
  [top, PicorubyTree.git_common_dir(common, top)]
end
