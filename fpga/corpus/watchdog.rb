# watchdog: 期限 (仮想の時計で 3ms) までに update しなくなると、コアごと再起動して初めから走る。
# 2回目は caused_reboot? が true になる
require "watchdog"

if Watchdog.caused_reboot?
  puts "Reboot by watchdog!"
  Watchdog.disable
  $LED = 2
else
  puts "Boot at first time!"
  $LED = 1
  Watchdog.enable(3)
  3.times do
    puts "I'm being watched!"
    sleep_ms 1
    Watchdog.update
  end
  puts "remain #{Watchdog.get_count > 0}"
  while true
    sleep_ms 1
    puts "I'm not being watched!"
  end
end
