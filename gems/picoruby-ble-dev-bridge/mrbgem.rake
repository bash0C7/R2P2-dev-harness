MRuby::Gem::Specification.new('picoruby-ble-dev-bridge') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Splits one BLE UART byte stream into REPL lines or DFU payload windows'

  # No dependency on picoruby-ble / picoruby-ble-uart / picoruby-dfu on purpose:
  # this is pure buffer bookkeeping, the same dependency-free shell shape as
  # picoruby-usb-peripheral. examples/rp2040/ble_dev_bridge.rb is where
  # BLE::UART / DFU::Updater / Sandbox actually get wired together.
  spec.require_name = 'ble_dev_bridge'
end
