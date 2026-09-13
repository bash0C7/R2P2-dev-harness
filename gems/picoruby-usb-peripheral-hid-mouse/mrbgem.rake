MRuby::Gem::Specification.new('picoruby-usb-peripheral-hid-mouse') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'USB::Peripheral binding for the USB HID mouse'

  spec.add_dependency 'picoruby-usb-peripheral'
  # No dependency on picoruby-usb-hid: its C only exists for rp2040, so the host
  # test VM could not link it. The r2p2 build_config already brings it in, and
  # HIDMouse requires "usb/hid" only when no hid object is handed in.
  spec.require_name = 'usb/peripheral/hid_mouse'
end
