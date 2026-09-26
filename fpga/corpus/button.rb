# $BUTTON が 1 の間だけ $LED を点ける
while true
  if $BUTTON == 1 then $LED = 1 else $LED = 0 end
end
