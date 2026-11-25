# Tamix IPTV · iPhone: turns the project `npx cap add ios` generates into
# Tamix's. Runs on the macOS build machine (GitHub Actions), from the folder
# that holds `capacitor.config.json`, `ios/` and `native/` (this file's
# folder). It copies the native Swift files into the app and adds them to its
# target, points the storyboard at MainViewController (which registers the
# plugins), lets the app reach providers over http, and adds VLC.
require 'fileutils'
require 'xcodeproj'

native = __dir__
root = Dir.pwd
app_dir = File.join(root, 'ios/App/App')
project_path = File.join(root, 'ios/App/App.xcodeproj')

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' } or abort('No App target')
group = project.main_group['App'] or abort('No App group')
Dir[File.join(native, '*.swift')].sort.each do |source|
  name = File.basename(source)
  FileUtils.cp(source, File.join(app_dir, name))
  next if group.files.any? { |file| file.path == name }
  target.source_build_phase.add_file_reference(group.new_reference(name))
  puts "added #{name}"
end
project.save

storyboard = File.join(app_dir, 'Base.lproj/Main.storyboard')
text = File.read(storyboard)
replaced = text.sub(
  /customClass="CAPBridgeViewController" customModule="Capacitor"/,
  'customClass="MainViewController" customModule="App" customModuleProvider="target"'
)
abort('Storyboard: CAPBridgeViewController not found') if replaced == text && !text.include?('MainViewController')
File.write(storyboard, replaced)

plist = File.join(app_dir, 'Info.plist')
buddy = lambda { |command| system('/usr/libexec/PlistBuddy', '-c', command, plist) }
buddy.call('Delete :NSAppTransportSecurity')
buddy.call('Add :NSAppTransportSecurity dict')
buddy.call('Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true')
buddy.call('Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent bool true')
buddy.call('Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsForMedia bool true')
buddy.call('Set :CFBundleDisplayName Tamix IPTV') || buddy.call('Add :CFBundleDisplayName string Tamix IPTV')
# Files the user downloads show in the Files app.
buddy.call('Add :UIFileSharingEnabled bool true')
buddy.call('Add :LSSupportsOpeningDocumentsInPlace bool true')

podfile = File.join(root, 'ios/App/Podfile')
pods = File.read(podfile)
unless pods.include?('MobileVLCKit')
  pods = pods.sub(/^(\s*)capacitor_pods\s*$/) { "#{$1}capacitor_pods\n#{$1}pod 'MobileVLCKit', '~> 3.6.0'" }
  abort('Podfile: capacitor_pods not found') unless pods.include?('MobileVLCKit')
  File.write(podfile, pods)
end
puts 'Tamix iOS project ready'
