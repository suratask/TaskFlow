require "xcodeproj"

project = Xcodeproj::Project.new("TaskFlow.xcodeproj")

development_team = "RUS98YNC4X"
marketing_version = "1.01"
project_version = "1"

target = project.new_target(:application, "TaskFlow", :ios, "17.0")
widget_target = project.new_target(:app_extension, "TaskFlowWidgets", :ios, "17.0")

group = project.main_group.new_group("TaskFlow", "TaskFlow")
sources_group = group.new_group("Sources")
resources_group = group.new_group("Resources", "Resources")
widgets_group = project.main_group.new_group("TaskFlowWidgets", "TaskFlowWidgets")
widget_sources_group = widgets_group.new_group("Sources")
widget_resources_group = widgets_group.new_group("Resources", "Resources")

source_paths = Dir.glob("TaskFlow/**/*.swift").sort
source_paths.each do |path|
  file = sources_group.new_file(path.sub("TaskFlow/", ""))
  target.add_file_references([file])
end

assets = resources_group.new_file("Assets.xcassets")
target.add_resources([assets])

widget_source_paths = Dir.glob("TaskFlowWidgets/**/*.swift").sort
widget_source_paths.each do |path|
  file = widget_sources_group.new_file(path.sub("TaskFlowWidgets/", ""))
  widget_target.add_file_references([file])
end

target.add_dependency(widget_target)
embed_phase = target.new_copy_files_build_phase("Embed App Extensions")
embed_phase.dst_subfolder_spec = "13"
embed_phase.add_file_reference(widget_target.product_reference, true)

project.root_object.attributes["TargetAttributes"] ||= {}
project.root_object.attributes["TargetAttributes"][target.uuid] = {
  "CreatedOnToolsVersion" => "26.5"
}
project.root_object.attributes["TargetAttributes"][widget_target.uuid] = {
  "CreatedOnToolsVersion" => "26.5"
}

project.build_configurations.each do |config|
  config.build_settings["DEVELOPMENT_TEAM"] = development_team
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["SDKROOT"] = "iphoneos"
  config.build_settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  config.build_settings["SWIFT_VERSION"] = "5.0"
end

target.build_configurations.each do |config|
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["CURRENT_PROJECT_VERSION"] = project_version
  config.build_settings["DEVELOPMENT_ASSET_PATHS"] = ""
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "TaskFlow/Resources/Info.plist"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["MARKETING_VERSION"] = marketing_version
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.surratt.TaskFlow"
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

widget_target.build_configurations.each do |config|
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["CURRENT_PROJECT_VERSION"] = project_version
  config.build_settings["DEVELOPMENT_TEAM"] = development_team
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "TaskFlowWidgets/Resources/Info.plist"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["MARKETING_VERSION"] = marketing_version
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.surratt.TaskFlow.widgets"
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["SKIP_INSTALL"] = "YES"
  config.build_settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

project.save
