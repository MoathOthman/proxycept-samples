Pod::Spec.new do |s|
  s.name = 'proxycept_logging'
  s.version = '0.1.0'
  s.summary = 'Protected private spool setup for Proxycept mobile logging.'
  s.description = 'Explicit mobile logging with bounded private, backup-excluded storage.'
  s.homepage = 'https://github.com/MoathOthman/proxycept-samples'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'Proxycept' => 'support@proxycept.com' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
end
