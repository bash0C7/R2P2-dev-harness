MRuby::Gem::Specification.new('picoruby-usb-peripheral-cdc-midi') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'USB::Peripheral binding for MIDI over USB CDC'

  spec.add_dependency 'picoruby-usb-peripheral'
  spec.add_dependency 'picoruby-usb-cdc-midi'
  spec.require_name = 'usb/peripheral/cdc_midi'
end
