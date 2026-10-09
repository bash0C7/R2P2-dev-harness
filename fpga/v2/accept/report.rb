# accept (計画 S1) の最後: assert.rb の report と、tally が覚えた assert ごとの結果 (@@ <結果> <名前>)
# C: none (D31)
report
$t_results.each do |r|
  t_print("@@ ", r[0], " ", r[1].inspect, "\n")
end
