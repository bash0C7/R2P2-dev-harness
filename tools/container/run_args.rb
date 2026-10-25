# Apple Container (`container` CLI) に渡す argv を組み立てる。ファイルシステムには触らない。
#
# 派生 image は作らない。ESP-IDF の image は展開後 9 GB (実測) あり、Apple Container は image ごとに
# 展開済み snapshot を持つので、派生 image を build すると snapshot がもう 1 つ増え、builder の中にも
# 同じだけ展開される。代わりに base image から常駐コンテナを 1 つ作り (create_argv)、足りない
# パッケージはそこへ一度だけ入れ、各タスクは exec で走らせる (exec_argv)。
#
# mount はホストと同じ絶対パスに張る。worktree の `.git` は元の clone の
# `.git/worktrees/<name>` を絶対パスで指すので、パスを変えると container の中で git が迷う。
module ContainerRun
  IMAGE = "docker.io/espressif/idf:v5.5.4".freeze
  NAME = "r2p2-dev-harness".freeze
  SUBMODULE_SLOT = "components/picoruby-esp32/picoruby".freeze

  # ホストの環境変数は全部は渡さない。PATH や HOME を渡すと container の toolchain を壊し、
  # token の類が container へ漏れる。build と rig の挙動を変えるものだけを通す。
  PASS_ENV_NAMES = %w[
    SDKCONFIG_DEFAULTS USE_WIFI HEAP_SIZE R2P2_ESP32_REPO
    PICORUBY_REPO PICORUBY_REF SKIP_BUILD MRUBY_CONFIG
  ].freeze
  PASS_ENV_PREFIXES = %w[EVQ_ QEMU_ PICORB_ PICORUBY_PSG_].freeze

  module_function

  # 常駐コンテナを作る `container run` の argv。mount は作るときにしか決められないので、
  # rake はこの argv を保存しておき、変わったらコンテナを作り直す。
  # esp32_picoruby は picoruby の tree (clone でも worktree でもよい)、picoruby_git_dir はその
  # `git rev-parse --git-common-dir`。worktree なら元の clone の .git になる。
  def create_argv(harness_root:, uid:, gid:, esp32_repo: nil, esp32_picoruby: nil, picoruby_git_dir: nil,
                  cpus: "8", memory: "8G", image: IMAGE, name: NAME)
    args = ["-d", "--name", name, "--uid", uid.to_s, "--gid", gid.to_s, "-c", cpus.to_s, "-m", memory.to_s]
    mounts(harness_root, esp32_repo, esp32_picoruby, picoruby_git_dir).each do |source, target|
      args.push("-v", "#{source}:#{target}")
    end
    cache_env(harness_root).each { |key, value| args.push("-e", "#{key}=#{value}") }
    # image の entrypoint が export.sh と git の safe.directory を済ませてから sleep に exec する
    args.push(image, "sleep", "infinity")
  end

  # 常駐コンテナでコマンドを走らせる `container exec` の argv。exec には entrypoint が掛からないので、
  # ESP-IDF の環境は毎回 export.sh で整える (idf: false で省く)。ruby_bin を渡すと、その Ruby を
  # PATH の先頭に置く。export.sh が PATH を書き換えるので、前置きはその後にする。
  def exec_argv(harness_root:, command:, uid:, gid:, workdir: nil, host_env: {}, tty: false,
                root: false, idf: true, ruby_bin: nil, name: NAME)
    args = []
    args.push("-i", "-t") if tty
    args.push("--uid", root ? "0" : uid.to_s, "--gid", root ? "0" : gid.to_s)
    args.push("-w", File.expand_path(workdir || harness_root, harness_root))
    passed_env(host_env).merge(cache_env(harness_root)).each { |key, value| args.push("-e", "#{key}=#{value}") }
    steps = []
    steps << %(. "$IDF_PATH/export.sh" >/dev/null 2>&1) if idf
    steps << %(export PATH="#{ruby_bin}:$PATH") if ruby_bin
    steps << command
    args.push(name, "bash", "-c", steps.join(" && "))
  end

  def mounts(harness_root, esp32_repo, esp32_picoruby, picoruby_git_dir)
    repo, tree, git_dir = [esp32_repo, esp32_picoruby, picoruby_git_dir].map { |path| path && File.expand_path(path, harness_root) }
    raise ArgumentError, "esp32_picoruby needs esp32_repo (the slot lives inside it)" if tree && !repo

    list = [[harness_root, harness_root]]
    # tree は slot とは別に自身のパスにも張る (DIR=<tree> で upstream のテストを回すため)。
    # どれも、すでに張った mount の中に見えていれば張らない。
    [repo, tree, git_dir].compact.each do |path|
      list << [path, path] unless list.any? { |source, _| inside?(path, source) }
    end
    # 親 (harness root か R2P2-ESP32) より後に張る。先に張ると親の mount に隠れる。
    list << [tree, File.join(repo, SUBMODULE_SLOT)] if tree
    list
  end

  # create_argv が組んだ (rake が保存した) argv の mount を [source, target] の組で読み戻す。
  def mounts_in(argv)
    argv.each_cons(2).select { |flag, _| flag == "-v" }.map { |_, spec| spec.split(":", 2) }
  end

  # esp32_repo の submodule の位置に重ねた tree。重ねていなければ nil。
  def slot_source(argv, esp32_repo)
    slot = File.join(esp32_repo, SUBMODULE_SLOT)
    pair = mounts_in(argv).find { |_, target| target == slot }
    pair && pair.first
  end

  def cache_env(harness_root)
    cache = File.join(harness_root, "tmp", "container")
    {
      "HOME" => File.join(cache, "home"),
      "BUNDLE_PATH" => File.join(cache, "bundle"),
      "CCACHE_DIR" => File.join(cache, "ccache"),
      "IDF_GIT_SAFE_DIR" => "*",
      # base image には LANG が無い。Ruby が QEMU の log (化けた byte を含む) を US-ASCII で読んで落ちる
      "LANG" => "C.UTF-8"
    }
  end

  def passed_env(host_env)
    host_env.select do |key, _|
      PASS_ENV_NAMES.include?(key) || PASS_ENV_PREFIXES.any? { |prefix| key.start_with?(prefix) }
    end
  end

  def inside?(path, root)
    path == root || path.start_with?("#{root}/")
  end
end
