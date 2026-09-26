# $LED を反転し、内側の while で待つ (issue #6 の実測に使った形)
$LED = 0
i = 0
while true
  $LED = 1 - $LED
  i += 1
  j = 0
  while j < 1000
    j += 1
  end
end
