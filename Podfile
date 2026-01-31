# Podfile for bitchat
# This adds XMTP with SQLCipher support (required for encrypted database)

platform :ios, '16.0'

# Disable CocoaPods analytics
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

target 'bitchat_iOS' do
  use_frameworks!

  # XMTP with SQLCipher - the CocoaPod properly includes SQLCipher dependency
  pod 'XMTP', '~> 4.9.0'
end

target 'bitchatTests_iOS' do
  use_frameworks!
  
  pod 'XMTP', '~> 4.9.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      config.build_settings['SWIFT_VERSION'] = '5.0'
      # Required for arm64 simulator builds
      config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'i386'
      # Disable user script sandboxing to fix rsync permission errors in Xcode 26
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
  
  # Fix Swift version for main project targets
  installer.generated_projects.each do |project|
    project.targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['SWIFT_VERSION'] = '5.0'
        config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      end
    end
  end
  
  # Include app xcconfig in Pods xcconfig so PRODUCT_BUNDLE_IDENTIFIER is resolved
  Dir.glob('Pods/Target Support Files/Pods-bitchat_iOS/*.xcconfig').each do |file|
    content = File.read(file)
    config_type = file.include?('debug') ? 'Debug' : 'Release'
    include_line = "#include \"../../../Configs/#{config_type}.xcconfig\"\n"
    unless content.include?(include_line)
      File.write(file, include_line + content)
    end
  end
end
