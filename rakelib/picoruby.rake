# PR の branch を harness 配下に worktree として置くタスク。
#
# vendor/picoruby (rake setup の upstream shallow clone) は生成物なので PR の作業には使わない。
# PR の branch は ghq の picoruby clone (PICORUBY_CLONE) から worktree を切り、
# vendor/worktrees/picoruby/<branch> に置く。container はこの clone も同じパスで mount する
# (worktree の .git が clone の .git/worktrees/<name> を絶対パスで指すため)。
PICORUBY_CLONE = ENV["PICORUBY_CLONE"] || File.expand_path("~/ghq/github.com/bash0C7/picoruby")
PICORUBY_WORKTREES = File.join(VENDOR_DIR, "worktrees", "picoruby")

namespace :picoruby do
  desc "Check out <branch> of PICORUBY_CLONE as a worktree at vendor/worktrees/picoruby/<branch>, submodules included"
  task :worktree, [:branch] do |_t, args|
    branch = args[:branch] or raise "usage: rake \"picoruby:worktree[<branch>]\""
    path = picoruby_worktree_path(branch)
    if File.exist?(File.join(path, ".git"))
      puts "#{path} is already there."
    else
      clone = require_picoruby_clone!
      sh "git", "-C", clone, "fetch", "origin", branch
      if system("git", "-C", clone, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
        sh "git", "-C", clone, "worktree", "add", path, branch
      else
        sh "git", "-C", clone, "worktree", "add", "--track", "-b", branch, path, "origin/#{branch}"
      end
    end
    sh "git", "-C", path, "submodule", "update", "--init", "--recursive"
  end

  desc "Remove the worktree vendor/worktrees/picoruby/<branch> (refuses while it has changes)"
  task :worktree_remove, [:branch] do |_t, args|
    branch = args[:branch] or raise "usage: rake \"picoruby:worktree_remove[<branch>]\""
    path = picoruby_worktree_path(branch)
    raise "#{path} is not a worktree." unless File.exist?(File.join(path, ".git"))

    # submodule を含む worktree は git が --force 無しでは外さない。--force は変更も捨てるので、
    # 変更が無いことを先にこちらで確かめてから使う。
    dirty = `git -C #{path.shellescape} status --porcelain --ignore-submodules=none`
    raise "#{path} has changes; commit or discard them first:\n#{dirty}" unless dirty.empty?

    sh "git", "-C", require_picoruby_clone!, "worktree", "remove", "--force", path
  end
end

def picoruby_worktree_path(branch)
  File.join(PICORUBY_WORKTREES, branch)
end

def require_picoruby_clone!
  return PICORUBY_CLONE if File.directory?(File.join(PICORUBY_CLONE, ".git"))

  raise "picoruby clone not found at #{PICORUBY_CLONE}. `ghq get bash0C7/picoruby` or set PICORUBY_CLONE."
end
