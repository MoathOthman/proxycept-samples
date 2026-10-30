require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))
Pod::Spec.new do |s|
  s.name = 'ProxyceptLoggingRN'
  s.version = package['version']
  s.summary = package['description']
  s.homepage = 'https://github.com/MoathOthman/proxycept-samples'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.authors = 'Proxycept contributors'
  s.source = { :git => 'https://github.com/MoathOthman/proxycept-samples.git', :tag => "v#{s.version}" }
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.source_files = 'ios/Core/**/*.swift', 'ios/Bridge/**/*.{swift,h,m}'
  s.dependency 'React-Core'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
