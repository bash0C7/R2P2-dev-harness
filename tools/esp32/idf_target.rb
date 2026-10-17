# Whether R2P2-ESP32's sdkconfig targets the DualKey's chip (ESP32-S3).
# R2P2-ESP32 expects a checkout that ran `rake setup_esp32s3`. A fresh
# clone's sdkconfig names no target, so idf.py builds for the plain ESP32:
# the DualKey's default config then overflows DRAM at link time, and the
# console overlay silently falls back to UART (no USB Serial/JTAG there).
module IdfTarget
  TARGET = "esp32s3".freeze

  module_function

  def set?(sdkconfig_text, target = TARGET)
    sdkconfig_text.match?(/^CONFIG_IDF_TARGET="#{Regexp.escape(target)}"$/)
  end
end
