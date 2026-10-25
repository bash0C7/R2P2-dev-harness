require "minitest/autorun"
require_relative "picoruby_tree"

class PicorubyTreeTest < Minitest::Test
  def test_submodules_marked_uninitialized_are_listed
    status = <<~OUT
      -1f2e3d4c5b6a7980 mrbgems/mruby-compiler2/lib/prism
       0a1b2c3d4e5f6071 mrbgems/picoruby-mruby/lib/mruby (3.4.0-12-g0a1b2c3)
      +9f8e7d6c5b4a3921 mrbgems/picoruby-mbedtls/mbedtls (v3.6.0)
      -abcdef0123456789 mrbgems/picoruby-net/lwip
    OUT
    assert_equal %w[mrbgems/mruby-compiler2/lib/prism mrbgems/picoruby-net/lwip],
                 PicorubyTree.uninitialized_submodules(status)
  end

  def test_an_all_initialized_tree_lists_none
    assert_empty PicorubyTree.uninitialized_submodules(" 0a1b2c3d mrbgems/picoruby-mruby/lib/mruby (3.4.0)\n")
    assert_empty PicorubyTree.uninitialized_submodules("")
  end

  def test_a_relative_git_common_dir_is_taken_from_the_tree
    # 普通の clone では git rev-parse --git-common-dir が ".git" と相対で返す
    assert_equal "/w/picoruby/.git", PicorubyTree.git_common_dir(".git\n", "/w/picoruby")
  end

  def test_a_worktree_git_common_dir_is_the_original_clone_git_dir
    assert_equal "/ghq/picoruby/.git", PicorubyTree.git_common_dir("/ghq/picoruby/.git\n", "/h/vendor/worktrees/topic")
  end
end
