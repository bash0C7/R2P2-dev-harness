# メソッドで書いた blink: LED を反転する toggle と、数えて待つ wait
def toggle(v)
  1 - v
end

def wait(n)
  i = 0
  while i < n
    i += 1
  end
end

$LED = 0
while true
  $LED = toggle($LED)
  wait(500)
end
