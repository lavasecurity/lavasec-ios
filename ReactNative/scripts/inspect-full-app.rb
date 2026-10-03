require_relative 'inspect-review-projects'
puts JSON.pretty_generate(inspect_projects(File.expand_path('..', __dir__), ['../LavaSec.xcodeproj', 'native-app/LavaSecRN.xcodeproj', 'native-app/Pods/Pods.xcodeproj']))
