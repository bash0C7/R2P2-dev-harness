# BLE event-path regression rig for picoruby PR #427 (QEMU, no radio).
#
# The rig injects synthetic GAP events into the NimBLE ring buffer from
# its own FreeRTOS task (firmware-patches/qemu-ble-evq) and judges the
# QEMU log with EvqVerdict: every event must reach Ruby within
# EVQ_MAX_LATENCY_MS, and nothing may push the Ruby queue from off the
# VM thread. evq_red and evq_green run the same rig; they differ only in
# the expected verdict (red = pre-fix firmware must fail).
#
# The overlay patches the PR branch's working copy and is never
# committed there; apply.sh/revert.sh own that lifecycle.
require_relative "../tools/esp32/evq_verdict"

namespace :esp32 do
  EVQ_MAX_LATENCY_MS = Integer(ENV["EVQ_MAX_LATENCY_MS"] || 50)

  desc "Build with the qemu-ble-evq overlay and collect the event-path log under QEMU (EVQ_VM=mruby|mrubyc)"
  task :evq_run do
    require_esp32_repo!
    rig = File.join(HARNESS_ROOT, "firmware-patches", "qemu-ble-evq")
    sh "bash #{File.join(rig, 'apply.sh').shellescape}"
    begin
      script = File.join(HARNESS_ROOT, "tools", "esp32", "evq_qemu_run.sh")
      FileUtils.cd(esp32_repo_dir) do
        # exit code covers "injector never finished"; the verdict decides the rest.
        ok = system("bash", script, evq_vm, evq_log_path)
        raise "evq_qemu_run.sh failed and #{evq_log_path} is missing" unless ok || File.file?(evq_log_path)
      end
    ensure
      sh "bash #{File.join(rig, 'revert.sh').shellescape}"
    end
    puts "[esp32:evq_run] log: #{evq_log_path}"
  end

  desc "Event-path rig, expecting FAIL (pre-fix firmware). Succeeds when the verdict is red"
  task :evq_red do
    result = evq_judge
    if result.pass
      puts "[esp32:evq_red] UNEXPECTED GREEN: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_red] RED as expected: #{result.message}"
  end

  desc "Event-path rig, expecting PASS (fixed firmware)"
  task :evq_green do
    result = evq_judge
    unless result.pass
      puts "[esp32:evq_green] FAIL: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_green] PASS: #{result.message}"
  end

  desc "Event-path rig + NoMemoryError inside BLE_write_data, expecting PASS (containment holds)"
  task :evq_oom_green do
    ENV["EVQ_OOM"] = "1"
    result = evq_judge(expect_fault: true)
    unless result.pass
      puts "[esp32:evq_oom_green] FAIL: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_oom_green] PASS: #{result.message}"
  end

  desc "Same fault with the containment stripped, expecting FAIL. Succeeds when the verdict is red"
  task :evq_oom_red do
    ENV["EVQ_OOM"] = "1"
    ENV["EVQ_OOM_RED"] = "1"
    result = evq_judge(expect_fault: true)
    if result.pass
      puts "[esp32:evq_oom_red] UNEXPECTED GREEN: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_oom_red] RED as expected: #{result.message}"
  end

  desc "Write-flood rig, 2 ms burst, expecting FAIL on pre-fix firmware. Succeeds when the verdict is red"
  task :evq_flood_red do
    ENV["EVQ_FLOOD"] = "1"
    ENV["EVQ_FLOOD_SPACING_MS"] ||= "2"
    result = evq_flood_judge
    if result.pass
      puts "[esp32:evq_flood_red] UNEXPECTED GREEN: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_flood_red] RED as expected: #{result.message}"
  end

  desc "Write-flood rig, 2 ms burst, expecting PASS (no abort, received + rejected == sent)"
  task :evq_flood_green do
    ENV["EVQ_FLOOD"] = "1"
    ENV["EVQ_FLOOD_SPACING_MS"] ||= "2"
    result = evq_flood_judge
    unless result.pass
      puts "[esp32:evq_flood_green] FAIL: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_flood_green] PASS: #{result.message}"
  end

  desc "Write-flood rig at link pace (33 ms), expecting PASS with nothing rejected"
  task :evq_flood_paced_green do
    ENV["EVQ_FLOOD"] = "1"
    ENV["EVQ_FLOOD_SPACING_MS"] = "33"
    result = evq_flood_judge(max_rejected: 0)
    unless result.pass
      puts "[esp32:evq_flood_paced_green] FAIL: #{result.message}"
      exit 1
    end
    puts "[esp32:evq_flood_paced_green] PASS: #{result.message}"
  end
end

def evq_vm
  ENV["EVQ_VM"] || "mruby"
end

def evq_log_path
  suffix = ""
  suffix << "-oom" if ENV["EVQ_OOM"] == "1"
  suffix << "-red" if ENV["EVQ_OOM_RED"] == "1"
  suffix << "-flood#{ENV['EVQ_FLOOD_SPACING_MS']}ms" if ENV["EVQ_FLOOD"] == "1"
  File.join(esp32_repo_dir, "qemu-evq-#{evq_vm}#{suffix}.log")
end

def evq_judge(expect_fault: false)
  Rake::Task["esp32:evq_run"].invoke
  raise "#{evq_log_path} was not produced" unless File.file?(evq_log_path)
  EvqVerdict.judge(File.read(evq_log_path), max_latency_ms: EVQ_MAX_LATENCY_MS, expect_fault: expect_fault, require_wlat: 20)
end

def evq_flood_default_heap
  evq_vm == "mruby" ? "217088" : "102400"
end

def evq_flood_judge(max_rejected: nil)
  ENV["EVQ_DONE_PATTERN"] = '\[rig\] flood done'
  ENV["EVQ_HEAP_SIZE"] ||= evq_flood_default_heap
  Rake::Task["esp32:evq_run"].invoke
  raise "#{evq_log_path} was not produced" unless File.file?(evq_log_path)
  EvqVerdict.judge_flood(File.read(evq_log_path), max_rejected: max_rejected)
end
