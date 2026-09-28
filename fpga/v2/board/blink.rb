# Lチカ (計画 §2.1)。LED_PIN は走らせる道具が頭に足す (tools/fpga/v2/pins.rb、板のモデルの Board::LED_PIN)
led = GPIO.new(LED_PIN, GPIO::OUT)
loop do
  led.write(1)
  sleep_ms 500
  led.write(0)
  sleep_ms 500
end
