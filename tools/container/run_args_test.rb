require "minitest/autorun"
require_relative "run_args"

class RunArgsTest < Minitest::Test
  HARNESS = "/Users/me/ghq/github.com/bash0C7/R2P2-dev-harness".freeze
  CLONE = "/Users/me/ghq/github.com/bash0C7/picoruby".freeze

  def create(**overrides)
    ContainerRun.create_argv(**{ harness_root: HARNESS, uid: 501, gid: 20 }.merge(overrides))
  end

  def exec(**overrides)
    ContainerRun.exec_argv(**{ harness_root: HARNESS, command: "rake -T", uid: 501, gid: 20 }.merge(overrides))
  end

  # "-v" の値だけを [source, target] の組で並べる
  def mounts_of(argv)
    argv.each_cons(2).select { |flag, _| flag == "-v" }.map { |_, spec| spec.split(":", 2) }
  end

  def env_of(argv)
    argv.each_cons(2).select { |flag, _| flag == "-e" }.to_h { |_, kv| kv.split("=", 2) }
  end

  def value_of(argv, flag)
    argv[argv.index(flag) + 1]
  end

  # --- create: 常駐コンテナを作る `container run` の argv ---

  def test_create_runs_detached_under_a_fixed_name_and_idles_after_the_image
    argv = create
    assert_equal "-d", argv.first
    assert_equal ContainerRun::NAME, value_of(argv, "--name")
    assert_equal [ContainerRun::IMAGE, "sleep", "infinity"], argv.last(3)
  end

  def test_harness_root_is_mounted_at_the_same_path
    assert_equal [[HARNESS, HARNESS]], mounts_of(create)
  end

  def test_the_git_dir_a_worktree_points_at_is_mounted_at_the_same_path
    # worktree の .git は元の clone の .git/worktrees/<name> を絶対パスで指す
    mounts = mounts_of(create(esp32_repo: "vendor/R2P2-ESP32", esp32_picoruby: "vendor/worktrees/picoruby/topic",
                              picoruby_git_dir: "#{CLONE}/.git"))
    assert_includes mounts, ["#{CLONE}/.git", "#{CLONE}/.git"]
    refute_includes mounts, [CLONE, CLONE]
  end

  def test_a_tree_outside_the_harness_is_also_mounted_at_its_own_path
    # DIR=<tree> で upstream のテストを回すときは、slot ではなく tree 自身のパスで走る
    tree = "/elsewhere/picoruby-topic"
    mounts = mounts_of(create(esp32_repo: "vendor/R2P2-ESP32", esp32_picoruby: tree))
    assert_includes mounts, [tree, tree]
    assert_includes mounts, [tree, "#{HARNESS}/vendor/R2P2-ESP32/components/picoruby-esp32/picoruby"]
  end

  def test_a_git_dir_already_visible_through_another_mount_is_not_mounted_again
    tree = "/elsewhere/picoruby"
    mounts = mounts_of(create(esp32_repo: "vendor/R2P2-ESP32", esp32_picoruby: tree, picoruby_git_dir: "#{tree}/.git"))
    refute_includes mounts, ["#{tree}/.git", "#{tree}/.git"]
    mounts = mounts_of(create(esp32_repo: "vendor/R2P2-ESP32", esp32_picoruby: "vendor/worktrees/picoruby/topic",
                              picoruby_git_dir: "#{HARNESS}/vendor/picoruby/.git"))
    assert_equal 2, mounts.size
  end

  def test_a_path_inside_the_harness_is_not_mounted_twice
    repo = "#{HARNESS}/vendor/R2P2-ESP32"
    assert_equal [[HARNESS, HARNESS]], mounts_of(create(esp32_repo: repo))
  end

  def test_a_sibling_whose_name_extends_the_harness_name_counts_as_outside
    sibling = "#{HARNESS}-old/R2P2-ESP32"
    assert_includes mounts_of(create(esp32_repo: sibling)), [sibling, sibling]
  end

  def test_esp32_picoruby_is_mounted_over_the_submodule_slot_after_its_parent
    repo = "/elsewhere/R2P2-ESP32"
    tree = "#{HARNESS}/vendor/worktrees/picoruby/picoruby-ble-esp32-port"
    mounts = mounts_of(create(esp32_repo: repo, esp32_picoruby: tree))
    slot = "#{repo}/components/picoruby-esp32/picoruby"
    assert_includes mounts, [tree, slot]
    assert_operator mounts.index([repo, repo]), :<, mounts.index([tree, slot])
  end

  def test_relative_paths_are_taken_from_the_harness_root
    mounts = mounts_of(create(esp32_repo: "vendor/R2P2-ESP32",
                              esp32_picoruby: "vendor/worktrees/picoruby/topic"))
    assert_includes mounts, ["#{HARNESS}/vendor/worktrees/picoruby/topic",
                             "#{HARNESS}/vendor/R2P2-ESP32/components/picoruby-esp32/picoruby"]
  end

  def test_esp32_picoruby_without_esp32_repo_is_an_error
    assert_raises(ArgumentError) { create(esp32_picoruby: "#{HARNESS}/vendor/worktrees/picoruby/topic") }
  end

  def test_create_runs_as_the_host_user_with_home_and_caches_under_tmp_container
    argv = create
    assert_equal "501", value_of(argv, "--uid")
    assert_equal "20", value_of(argv, "--gid")
    env = env_of(argv)
    assert_equal "#{HARNESS}/tmp/container/home", env["HOME"]
    assert_equal "#{HARNESS}/tmp/container/bundle", env["BUNDLE_PATH"]
    assert_equal "#{HARNESS}/tmp/container/ccache", env["CCACHE_DIR"]
    assert_equal "*", env["IDF_GIT_SAFE_DIR"]
  end

  def test_cpus_and_memory_default_and_can_be_changed
    argv = create
    assert_equal "8", value_of(argv, "-c")
    assert_equal "8G", value_of(argv, "-m")
    argv = create(cpus: "4", memory: "6G")
    assert_equal "4", value_of(argv, "-c")
    assert_equal "6G", value_of(argv, "-m")
  end

  def test_the_same_inputs_give_the_same_create_argv
    # rake はこれを保存して比べ、違えばコンテナを作り直す
    assert_equal create(esp32_repo: "vendor/R2P2-ESP32"), create(esp32_repo: "vendor/R2P2-ESP32")
    refute_equal create, create(esp32_repo: "/elsewhere/R2P2-ESP32")
  end

  def test_the_mounts_of_a_saved_argv_can_be_read_back
    # rake は保存した argv から、今も host に mount 元があるか、slot に何を重ねたかを読む
    argv = create(esp32_repo: "vendor/R2P2-ESP32", esp32_picoruby: "/elsewhere/picoruby",
                  picoruby_git_dir: "/elsewhere/clone/.git")
    assert_equal mounts_of(argv), ContainerRun.mounts_in(argv)
  end

  def test_the_tree_on_the_slot_can_be_read_back_from_a_saved_argv
    repo = "#{HARNESS}/vendor/R2P2-ESP32"
    argv = create(esp32_repo: repo, esp32_picoruby: "/elsewhere/picoruby")
    assert_equal "/elsewhere/picoruby", ContainerRun.slot_source(argv, repo)
    assert_nil ContainerRun.slot_source(create(esp32_repo: repo), repo)
  end

  # --- exec: 常駐コンテナでコマンドを走らせる `container exec` の argv ---

  def test_exec_targets_the_container_and_sources_the_idf_environment_first
    argv = exec(command: "rake esp32:evq_green")
    assert_equal ContainerRun::NAME, argv[-4]
    assert_equal %w[bash -c], argv[-3, 2]
    assert_match(/\A\. "\$IDF_PATH\/export\.sh" >\/dev\/null 2>&1 && rake esp32:evq_green\z/, argv.last)
  end

  def test_exec_can_put_a_built_ruby_first_on_path_after_the_idf_environment
    # export.sh は PATH を書き換えるので、Ruby の bin はその後に前置きする
    script = exec(command: "rake test:gems:steep", ruby_bin: "/h/tmp/container/ruby/4.0.1/bin").last
    assert_equal %(. "$IDF_PATH/export.sh" >/dev/null 2>&1 && export PATH="/h/tmp/container/ruby/4.0.1/bin:$PATH" && rake test:gems:steep),
                 script
  end

  def test_exec_without_idf_runs_the_command_as_is
    assert_equal "apt-get update", exec(command: "apt-get update", idf: false).last
  end

  def test_exec_passes_only_listed_host_env_and_keeps_home_in_tmp_container
    env = env_of(exec(host_env: { "EVQ_VM" => "mrubyc", "SDKCONFIG_DEFAULTS" => "a;b",
                                  "PICORB_TASK_STACK_SIZE" => "16384", "PATH" => "/opt/homebrew/bin",
                                  "HOME" => "/Users/me", "GITHUB_TOKEN" => "secret" }))
    assert_equal "mrubyc", env["EVQ_VM"]
    assert_equal "a;b", env["SDKCONFIG_DEFAULTS"]
    assert_equal "16384", env["PICORB_TASK_STACK_SIZE"]
    assert_equal "#{HARNESS}/tmp/container/home", env["HOME"]
    refute env.key?("PATH")
    refute env.key?("GITHUB_TOKEN")
  end

  def test_exec_and_create_read_text_as_utf8
    # base image には LANG が無く、Ruby が QEMU の log を US-ASCII で読んで落ちた
    assert_equal "C.UTF-8", env_of(exec)["LANG"]
    assert_equal "C.UTF-8", env_of(create)["LANG"]
  end

  def test_exec_runs_as_the_host_user_or_as_root_when_asked
    argv = exec
    assert_equal "501", value_of(argv, "--uid")
    argv = exec(root: true)
    assert_equal "0", value_of(argv, "--uid")
    assert_equal "0", value_of(argv, "--gid")
  end

  def test_exec_tty_flags_only_when_asked
    refute_includes exec, "-t"
    assert_equal %w[-i -t], exec(tty: true).first(2)
  end

  def test_exec_workdir_defaults_to_the_harness_root_and_accepts_relative_paths
    assert_equal HARNESS, value_of(exec, "-w")
    assert_equal "#{HARNESS}/vendor/R2P2-ESP32", value_of(exec(workdir: "vendor/R2P2-ESP32"), "-w")
  end
end
