require "minitest/autorun"
require_relative "idf_target"

class IdfTargetTest < Minitest::Test
  def test_a_sdkconfig_for_the_esp32s3_is_set
    assert IdfTarget.set?(%(CONFIG_IDF_TARGET_ARCH="xtensa"\nCONFIG_IDF_TARGET="esp32s3"\n))
  end

  def test_a_sdkconfig_that_fell_back_to_the_plain_esp32_is_not_set
    # a fresh clone built without set-target falls back to the plain ESP32
    refute IdfTarget.set?(%(CONFIG_IDF_TARGET="esp32"\n))
  end

  def test_a_missing_sdkconfig_is_not_set
    # right after ensure_console_overlay! deleted it
    refute IdfTarget.set?("")
  end

  def test_only_the_target_line_counts
    refute IdfTarget.set?(%(# CONFIG_IDF_TARGET="esp32s3" is the DualKey\nCONFIG_IDF_TARGET="esp32"\n))
  end
end
