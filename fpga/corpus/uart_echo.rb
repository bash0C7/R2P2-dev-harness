# 入力の刺激で動くデバイス: UART が受けた行を送り返し、ボタン (GPIO 5、pull up、押すと L) を $LED に写す。
# 刺激は uart_echo.stim (番地 289 = 0x121 は UART の受信バイト、262 = 0x106 は外から L にするピン)
uart = UART.new(unit: :RP2040_UART0, baudrate: 115_200)
button = GPIO.new(5, GPIO::IN | GPIO::PULL_UP)
n = 0
while n < 3
  line = uart.gets
  if line
    uart.write("echo: " + line)
    n += 1
  end
  $LED = button.low? ? 1 : 0
  sleep_ms 1
end
puts "done"
