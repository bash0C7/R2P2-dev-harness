# accept (計画 S1) の tally: mruby の test/assert.rb の後、test/t の file の前に読む。assert.rb は変えない。
# 一番外の assert ごとに、assert.rb の数 ($ok_test ほか) の増え方から結果を決めて覚える。入れ子の assert はそのまま通す
# C: none (D31)
$t_results = []

alias __t_assert assert

def assert(str = "assert", iso = "", &block)
  return __t_assert(str, iso, &block) if $mrbtest_assert_idx && !$mrbtest_assert_idx.empty?

  ok = $ok_test
  ko = $ko_test
  kill = $kill_test
  warn = $warning_test
  skip = $skip_test
  __t_assert(str, iso, &block)
  r = if $kill_test > kill
        "Crash"
      elsif $ko_test > ko
        "KO"
      elsif $skip_test > skip
        "Skip"
      elsif $warning_test > warn
        "Warn"
      elsif $ok_test > ok
        "OK"
      else
        "None"
      end
  $t_results << [r, str]
  nil
end
