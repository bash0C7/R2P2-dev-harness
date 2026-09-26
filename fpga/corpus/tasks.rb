# Task (P6): 協調・時分割のマルチタスク。出力の順は sleep の間隔 (20ms の倍数、host の tick 4ms でも同じ順になる幅) で決まる
log = []

a = Task.new(name: "a") do
  3.times do |i|
    log << "a#{i}"
    sleep_ms 40
  end
  :a_done
end

b = Task.new(name: "b", priority: 100) do
  3.times do |i|
    log << "b#{i}"
    sleep_ms 60
  end
end

q = Task::Queue.new
consumer = Task.new(name: "consumer") do
  got = []
  while (v = q.pop)
    got << v
  end
  log << "got #{got.join(',')}"
end

producer = Task.new(name: "producer") do
  4.times do |i|
    q << i * i
    sleep_ms 20
  end
  q.close
end

sleep_ms 10
puts "main: #{Task.current.name} #{a.status} #{b.status}"
p [a.priority, b.priority, Task.get("consumer").name]

# suspend / resume / terminate (spin は優先度が低く、譲らずに回り続ける。main が起きると timeslice の途中でも降ろされる)
spin = Task.new(name: "spin", priority: 200) do
  n = 0
  while true
    n += 1
  end
end
sleep_ms 5
spin.suspend
puts "spin #{spin.status}"
spin.resume
puts "spin #{spin.status}"
spin.terminate
puts "spin #{spin.status}"

r = a.join
p r
sleep_ms 200
p a.value
p log
puts Task.list.map { |t| "#{t.name}:#{t.status}" }.join(" ")

# 例外はタスクの結果になる
bad = Task.new(name: "bad") { raise ArgumentError, "oops" }
sleep_ms 10
p bad.value.class
p bad.value.message
begin
  q.push(1)
rescue Task::Error => e
  puts "closed: #{e.message}"
end
