Pod::Spec.new do |s|
  s.name             = 'nikon_ptp_flutter'
  s.version          = '0.1.0'
  s.summary          = 'iOS ImageCaptureCore (ICCameraDevice) PTP bridge for the nikon_ptp package.'
  s.description      = <<-DESC
Wraps `ICDeviceBrowser` + `ICCameraDevice.requestSendPTPCommand` so a Flutter
app can talk PTP to a USB-C connected Nikon Z body without MFi certification.
                       DESC
  s.homepage         = 'https://github.com/Rabbit95/che'
  s.license          = { :type => 'Proprietary', :text => 'Internal use only.' }
  s.author           = { 'Rabbit' => 'rabbit95@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{swift,h,m}'
  s.dependency 'Flutter'
  s.frameworks       = 'ImageCaptureCore'
  s.platform         = :ios, '13.2'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
