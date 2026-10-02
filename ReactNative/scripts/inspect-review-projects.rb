# Emits only build-graph data for the isolated review workspace. No environment,
# signing state, credential files, or unrelated Xcode projects are read.
require 'json'
require 'xcodeproj'
require 'pathname'

def inspect_projects(root, projects)
projects.map do |relative|
  project = Xcodeproj::Project.open(File.join(root, relative))
  targets = project.targets.map do |target|
    source_paths = ->(phase) {
      (phase&.files_references || []).map { |file| Pathname.new(file.real_path).relative_path_from(Pathname.new(root)).to_s }.sort
    }
    {
      name: target.name,
      settings: target.build_configurations.to_h { |config| [config.name, config.build_settings] },
      baseConfigurations: target.build_configurations.to_h { |config| [config.name, config.base_configuration_reference&.path] },
      copies: target.respond_to?(:copy_files_build_phases) ? target.copy_files_build_phases.map { |phase| {name: phase.name, destination: phase.dst_subfolder_spec, files: phase.files_references.map(&:path).sort} } : [],
      type: target.respond_to?(:product_type) ? target.product_type : target.isa,
      sources: source_paths.call(target.respond_to?(:source_build_phase) ? target.source_build_phase : nil),
      resources: source_paths.call(target.respond_to?(:resources_build_phase) ? target.resources_build_phase : nil),
      phases: target.build_phases.map(&:isa),
      frameworks: target.respond_to?(:frameworks_build_phase) ? target.frameworks_build_phase.files.map { |entry| entry.file_ref ? {path: entry.file_ref.path, tree: entry.file_ref.source_tree} : {product: entry.product_ref&.product_name} } : [],
      rules: target.respond_to?(:build_rules) ? target.build_rules.map(&:to_hash) : [],
      products: target.respond_to?(:package_product_dependencies) ? target.package_product_dependencies.map(&:product_name).sort : [],
      dependencies: target.dependencies.map { |dep| dep.target&.name || dep.name }.compact.sort,
      scripts: target.shell_script_build_phases.map { |phase| {name: phase.name, shell: phase.shell_path, body: phase.shell_script} },
      entitlements: target.build_configurations.filter_map { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] }.uniq,
    }
  end
  packages = project.root_object.package_references.map do |package|
    {type: package.isa, path: package.respond_to?(:relative_path) ? package.relative_path : nil,
     url: package.respond_to?(:repositoryURL) ? package.repositoryURL : nil}
  end
  {project: relative, packages: packages, targets: targets.sort_by { |target| target[:name] }}
end
end
if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(inspect_projects(File.expand_path('..', __dir__), ['ios/LavaSecUIReview.xcodeproj', 'ios/Pods/Pods.xcodeproj']))
end
