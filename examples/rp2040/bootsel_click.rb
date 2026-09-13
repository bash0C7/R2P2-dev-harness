# USB マウスとして、Pico 2 W の BOOTSEL ボタンを左クリックにする。
#
#   rake rp2040:run[examples/rp2040/bootsel_click.rb,30]
#
# 押している間に抜けても、器がボタンを離すので host に押しっぱなしを残さない。
require "usb/peripheral/hid_mouse"

USB::Peripheral::HIDMouse.new(idle_ms: 0).run do |dev|
  dev.setup do
    puts "USB mouse ready"
  end

  dev.tick do |d|
    pressed = Machine.bootsel_pressed?
    down = d.held.include?(:left)
    # 送れなかったら次の tick でもう一度。held は送れた時だけ変わる。
    if pressed && !down
      puts "press" if d.press(:left)
    elsif !pressed && down
      puts "release" if d.release(:left)
    end
    d.wait(10)
  end

  dev.teardown do
    puts "USB mouse gone"
  end
end
