# container に渡す picoruby の tree をホストの git の出力から読む。git を呼ぶのは rake の側。
#
# tree は clone でも worktree でもよく、誰が作ったか (Claude Code、cmux、手の git worktree) は問わない。
module PicorubyTree
  module_function

  # `git submodule status --recursive` で "-" が付いた (init されていない) submodule のパス。
  # 1 つでも残っていると picoruby は build の途中で分かりにくく落ちる。
  def uninitialized_submodules(status_text)
    status_text.each_line.select { |line| line.start_with?("-") }.map { |line| line.split[1] }
  end

  # `git rev-parse --git-common-dir` は普通の clone では ".git" と相対で返す。
  def git_common_dir(rev_parse_output, tree)
    File.expand_path(rev_parse_output.strip, tree)
  end
end
