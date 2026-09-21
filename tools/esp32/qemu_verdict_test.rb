require "minitest/autorun"
require_relative "qemu_verdict"

class QemuVerdictTest < Minitest::Test
  def test_guru_meditation_after_app_main_fails
    log = <<~LOG
      I (262) main_task: Returned from app_main()
      Guru Meditation Error: Core  1 panic'ed (LoadProhibited). Exception was unhandled.
    LOG
    r = QemuVerdict.judge(log)
    refute r.pass
    assert_includes r.message, "Guru Meditation Error"
  end

  def test_rebooting_fails
    r = QemuVerdict.judge("I (258) main_task: Returned from app_main()\nRebooting...\n")
    refute r.pass
    assert_includes r.message, "Rebooting..."
  end

  def test_app_main_without_prompt_passes_with_note
    log = "I (258) main_task: Returned from app_main()\n== Timed out after 60s waiting for the shell prompt ==\n"
    r = QemuVerdict.judge(log)
    assert r.pass
    assert_includes r.message, "not reached"
  end

  def test_prompt_reached_passes
    r = QemuVerdict.judge("I (258) main_task: Returned from app_main()\n$> \n")
    assert r.pass
    assert_includes r.message, "prompt reached"
  end

  def test_no_app_main_fails
    r = QemuVerdict.judge("ESP-ROM:esp32s3-20210327\nboot: ...\n")
    refute r.pass
    assert_includes r.message, "boot not reached"
  end
end
