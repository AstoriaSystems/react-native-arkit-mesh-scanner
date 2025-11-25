require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-arkit-mesh-scanner"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/AstoriaSystems/react-native-arkit-mesh-scanner.git", :tag => "#{s.version}" }

  s.source_files = "ios/ARKitMeshScanner/**/*.{h,m,mm,swift}"
  s.swift_version = "5.0"

  s.dependency "React-Core"

  s.frameworks = "ARKit", "RealityKit", "Metal", "MetalKit"

  s.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_COMPILATION_MODE" => "wholemodule"
  }
end
