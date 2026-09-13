MRuby::Gem::Specification.new('picoruby-usb-peripheral') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Lifecycle for turning PicoRuby into a USB peripheral'

  # No dependency on any concrete USB gem on purpose: this is the shell.
  # A binding gem (picoruby-usb-peripheral-cdc-midi and friends) brings its own.
  spec.require_name = 'usb/peripheral'
end
