Pod::Spec.new do |s|
  s.name           = 'CameraPiP'
  s.version        = '1.0.0'
  s.summary        = 'MJPEG chamber camera rendered into AVSampleBufferDisplayLayer, with Picture-in-Picture.'
  s.description    = 'Decodes the printer MJPEG stream in-app and feeds AVPictureInPictureController via a sample-buffer content source, so PiP works without transcoding to HLS.'
  s.author         = ''
  s.homepage       = 'https://github.com/sadontsev/sprout'
  s.license        = { :type => 'MIT' }
  # Matches the app's deployment target; withIosPodMinDeploymentTarget.js force-bumps pods below it.
  s.platforms      = { :ios => '16.4' }
  s.source         = { :git => '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks   = 'AVKit', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'ImageIO'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = '**/*.{h,m,mm,swift,hpp,cpp}'
end
