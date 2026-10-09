require 'fileutils'
require 'xcodeproj'
root = __dir__
path = File.join(root, 'SimPair.xcodeproj')
FileUtils.rm_rf(path)
p = Xcodeproj::Project.new(path)
host = p.new_target(:application, 'SimPairHost', :ios, '17.0')
host.add_file_references([p.main_group.new_file('HostApp/HostApp.swift')])
host.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.roachwares.simpair.host'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
end
ui = p.new_target(:ui_test_bundle, 'SimPairUITests', :ios, '17.0')
ui.add_file_references([p.main_group.new_file('UITests/PairingUITests.swift')])
ui.add_dependency(host)
ui.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.roachwares.simpair.uitests'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['TEST_TARGET_NAME'] = 'SimPairHost'
end
p.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_test_target(ui)
scheme.set_launch_target(host)
scheme.save_as(path, 'SimPair', true)
puts 'generated'
