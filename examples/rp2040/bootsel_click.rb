# USB マウスとして、Pico 2 W の BOOTSEL ボタンを左クリックにする。
# 押している間は基板の LED を点ける。
#
#   rake rp2040:run[examples/rp2040/bootsel_click.rb,30]
#
# tick の中で例外が raise されて抜けた時は、器がボタンを離すので host に
# 押しっぱなしを残さない。ただし Ctrl-C (rake rp2040:run が最後に送るものを
# 含む) はこの teardown を経由しない — 押している間に Ctrl-C で止めると
# host に押しっぱなしが残り得る (issue #14, docs/spec.md §2)。
require "usb/peripheral/hid_mouse"
require "cyw43"

# Pico 2 W の LED は RP2350 ではなく無線チップ CYW43 の GPIO に繋がっている。
CYW43.init unless CYW43.initialized?
led = CYW43::GPIO.new(CYW43::GPIO::LED_PIN)
led.write(0)

USB::Peripheral::HIDMouse.new(idle_ms: 0).run do |dev|
  dev.setup do
    puts "USB mouse ready"
  end

  dev.tick do |d|
    pressed = Machine.bootsel_pressed?
    down = d.held.include?(:left)
    # 送れなかったら次の tick でもう一度。held は送れた時だけ変わる。
    if pressed && !down
      if d.press(:left)
        led.write(1)
        puts "press"
      end
    elsif !pressed && down
      if d.release(:left)
        led.write(0)
        puts "release"
      end
    end
    d.wait(10)
  end

  dev.teardown do
    led.write(0)
    puts "USB mouse gone"
  end
end
