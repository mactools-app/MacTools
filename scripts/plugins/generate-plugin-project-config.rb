#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"
require "pathname"
require "shellwords"
require "yaml"

options = {
  source_dir: "Plugins",
  output: "Configs/GeneratedPlugins.yml"
}

OptionParser.new do |opts|
  opts.banner = "Usage: generate-plugin-project-config.rb [--source-dir Plugins] [--output Configs/GeneratedPlugins.yml]"
  opts.on("--source-dir PATH", "Plugin source directory") { |value| options[:source_dir] = value }
  opts.on("--output PATH", "Generated XcodeGen spec output") { |value| options[:output] = value }
end.parse!

repo_root = File.expand_path("../..", __dir__)
source_dir = File.expand_path(options[:source_dir], repo_root)
output_path = File.expand_path(options[:output], repo_root)
output_dir = File.dirname(output_path)

unless Dir.exist?(source_dir)
  warn "Plugin source directory not found: #{source_dir}"
  exit 1
end

def read_yaml(path)
  return {} unless File.file?(path)

  YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
rescue Psych::SyntaxError => e
  warn "Invalid YAML in #{path}: #{e.message}"
  exit 1
end

def camelize_id(value)
  value
    .split(/[^A-Za-z0-9]+/)
    .reject(&:empty?)
    .map { |part| part[0].upcase + part[1..] }
    .join
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    if old_value.is_a?(Hash) && new_value.is_a?(Hash)
      deep_merge(old_value, new_value)
    else
      new_value
    end
  end
end

def relative_to_output_dir(path, output_dir)
  Pathname(File.expand_path(path)).relative_path_from(Pathname(output_dir)).to_s
end

def normalize_fragment_path(plugin_relative_dir, item, repo_root, output_dir)
  case item
  when String
    { "path" => relative_to_output_dir(File.join(repo_root, plugin_relative_dir, item), output_dir) }
  when Hash
    normalized = item.transform_keys(&:to_s)
    path = normalized["path"]
    if path && !path.start_with?("/", "$(")
      absolute_path = if path.start_with?("#{plugin_relative_dir}/")
        File.join(repo_root, path)
      else
        File.join(repo_root, plugin_relative_dir, path)
      end
      normalized["path"] = relative_to_output_dir(absolute_path, output_dir)
    end
    normalized
  else
    item
  end
end

def split_setting_words(value)
  return [] if value.nil? || value.to_s.strip.empty?

  Shellwords.split(value.to_s)
rescue ArgumentError
  value.to_s.split
end

def collect_words(target, value)
  split_setting_words(value).each do |word|
    target << word unless target.include?(word)
  end
end

def collect_ldflags(target, value)
  words = split_setting_words(value)
  index = 0
  while index < words.length
    word = words[index]
    if ["-framework", "-weak_framework", "-F"].include?(word) && index + 1 < words.length
      flag = "#{word} #{words[index + 1]}"
      target << flag unless target.include?(flag)
      index += 2
    else
      target << word unless target.include?(word)
      index += 1
    end
  end
end

def yaml_scalar(value)
  case value
  when true
    "true"
  when false
    "false"
  when Numeric
    value.to_s
  else
    string = value.to_s
    if string.empty? || string.match?(/[:#\[\]\{\},&\*!\|>'"%@`]/) || string.match?(/\A(?:true|false|null|yes|no|on|off|\d)/i) || string.include?("$(")
      string.dump
    else
      string
    end
  end
end

def write_yaml(io, value, indent = 0)
  spaces = " " * indent
  case value
  when Hash
    value.each do |key, child|
      if child.is_a?(Hash)
        io << "#{spaces}#{key}:\n"
        write_yaml(io, child, indent + 2)
      elsif child.is_a?(Array)
        io << "#{spaces}#{key}:\n"
        write_yaml(io, child, indent + 2)
      else
        io << "#{spaces}#{key}: #{yaml_scalar(child)}\n"
      end
    end
  when Array
    value.each do |child|
      if child.is_a?(Hash)
        first = true
        child.each do |key, nested|
          prefix = first ? "#{spaces}- " : "#{" " * (indent + 2)}"
          if nested.is_a?(Hash) || nested.is_a?(Array)
            io << "#{prefix}#{key}:\n"
            write_yaml(io, nested, indent + 4)
          else
            io << "#{prefix}#{key}: #{yaml_scalar(nested)}\n"
          end
          first = false
        end
      else
        io << "#{spaces}- #{yaml_scalar(child)}\n"
      end
    end
  else
    io << "#{spaces}#{yaml_scalar(value)}\n"
  end
end

plugin_roots = Dir.children(source_dir)
  .map { |entry| File.join(source_dir, entry) }
  .select { |path| File.file?(File.join(path, "plugin.json")) }
  .sort_by { |path| File.basename(path).downcase }

targets = {}
plugin_schemes = {}
plugin_bundle_targets = []
plugin_core_targets = []
test_include_paths = []
test_ldflags = []

plugin_roots.each do |plugin_root|
  manifest_path = File.join(plugin_root, "plugin.json")
  manifest = JSON.parse(File.read(manifest_path))
  fragment = read_yaml(File.join(plugin_root, "project.yml")).transform_keys(&:to_s)
  build = (manifest["build"] || {}).merge(fragment.fetch("build", {}))

  plugin_id = manifest.fetch("id")
  plugin_relative_dir = Pathname(File.expand_path(plugin_root)).relative_path_from(Pathname(repo_root)).to_s
  scheme = build["scheme"] || "#{camelize_id(plugin_id)}Plugin"
  module_name = build["moduleName"] || manifest["factoryClass"].to_s.split(".").first || scheme
  bundle_relative_path = manifest.fetch("bundleRelativePath")
  product_name = build["productName"] || File.basename(bundle_relative_path, ".bundle")
  bundle_module_name = build["bundleModuleName"] || "#{module_name}Bundle"
  core_target = build["coreTarget"] || "#{scheme}Core"
  bundle_target = build["bundleTarget"] || scheme

  common_settings = {
    "GENERATE_INFOPLIST_FILE" => "YES",
    "SWIFT_VERSION" => "6.0",
    "DEVELOPMENT_LANGUAGE" => "zh-Hans",
    "MACOSX_DEPLOYMENT_TARGET" => "14.0",
    "CODE_SIGN_STYLE" => "Automatic",
    "DEVELOPMENT_TEAM" => "$(DEVELOPMENT_TEAM)"
  }

  shared_settings = fragment.fetch("settings", {})
  core_settings = deep_merge(
    {
      "base" => common_settings.merge(
        "PRODUCT_MODULE_NAME" => module_name,
        "PRODUCT_NAME" => core_target,
        "PRODUCT_BUNDLE_IDENTIFIER" => "$(BUNDLE_IDENTIFIER_PREFIX).mactools.plugins.#{plugin_id}.core"
      )
    },
    shared_settings
  )
  core_settings = deep_merge(core_settings, fragment.dig("core", "settings") || {})

  bundle_settings = deep_merge(
    {
      "base" => common_settings.merge(
        "PRODUCT_NAME" => product_name,
        "PRODUCT_MODULE_NAME" => bundle_module_name,
        "PRODUCT_BUNDLE_IDENTIFIER" => "$(BUNDLE_IDENTIFIER_PREFIX).mactools.plugins.#{plugin_id}"
      )
    },
    shared_settings
  )
  bundle_settings = deep_merge(bundle_settings, fragment.dig("bundle", "settings") || {})

  [core_settings, bundle_settings, fragment.dig("tests", "settings") || {}].each do |settings|
    base = settings["base"] || {}
    collect_words(test_include_paths, base["SWIFT_INCLUDE_PATHS"])
    collect_ldflags(test_ldflags, base["OTHER_LDFLAGS"])
  end

  core_sources = [{ "path" => relative_to_output_dir(File.join(plugin_root, "Sources"), output_dir) }]
  Array(fragment.dig("core", "sources")).each do |item|
    core_sources << normalize_fragment_path(plugin_relative_dir, item, repo_root, output_dir)
  end

  bundle_sources = [{ "path" => relative_to_output_dir(File.join(plugin_root, "Bundle"), output_dir) }]
  plugin_resources_dir = File.join(plugin_root, "Resources")
  if Dir.exist?(plugin_resources_dir)
    bundle_sources << { "path" => relative_to_output_dir(plugin_resources_dir, output_dir) }
  end
  Array(fragment.dig("bundle", "sources")).each do |item|
    bundle_sources << normalize_fragment_path(plugin_relative_dir, item, repo_root, output_dir)
  end

  extra_targets = {}
  extra_bundle_dependencies = []
  extra_scheme_targets = []
  generated_post_build_scripts = []
  Array(fragment.fetch("targets", {})).each do |target_name, target_spec|
    target_name = target_name.to_s
    normalized_spec = target_spec.transform_keys(&:to_s)
    normalized_sources = []
    Array(normalized_spec["sources"]).each do |item|
      normalized_sources << normalize_fragment_path(plugin_relative_dir, item, repo_root, output_dir)
    end

    normalized_settings = normalized_spec["settings"] || {}
    base_settings = normalized_settings["base"] || {}
    collect_words(test_include_paths, base_settings["SWIFT_INCLUDE_PATHS"])
    collect_ldflags(test_ldflags, base_settings["OTHER_LDFLAGS"])

    target_hash = normalized_spec.reject { |key, _| key == "bundleResourcePath" }
    target_hash["sources"] = normalized_sources unless normalized_sources.empty?
    target_dependencies = Array(normalized_spec["dependencies"])
    target_hash["dependencies"] = target_dependencies unless target_dependencies.empty?
    target_hash["settings"] = normalized_settings unless normalized_settings.empty?
    extra_targets[target_name] = target_hash

    resource_path = normalized_spec["bundleResourcePath"]
    next unless resource_path

    extra_bundle_dependencies << { "target" => target_name, "link" => false }
    extra_scheme_targets << target_name
    generated_post_build_scripts << {
      "name" => "Copy #{target_name}",
      "script" => [
        "set -euo pipefail",
        "resource_dir=\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/#{resource_path}\"",
        "mkdir -p \"$resource_dir\"",
        "ditto \"$BUILT_PRODUCTS_DIR/#{target_name}\" \"$resource_dir/#{target_name}\"",
        "chmod 755 \"$resource_dir/#{target_name}\""
      ].join("\n"),
      "inputFiles" => ["$(BUILT_PRODUCTS_DIR)/#{target_name}"],
      "outputFiles" => ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/#{resource_path}/#{target_name}"]
    }
  end

  targets.merge!(extra_targets)

  targets[core_target] = {
    "type" => "library.static",
    "platform" => "macOS",
    "deploymentTarget" => "14.0",
    "configFiles" => {
      "Debug" => "Debug.xcconfig",
      "Nightly" => "Release.xcconfig",
      "Release" => "Release.xcconfig"
    },
    "sources" => core_sources,
    "dependencies" => [{ "target" => "MacToolsPluginKit" }] + Array(fragment.dig("core", "dependencies")),
    "settings" => core_settings
  }

  bundle_post_build_scripts = Array(fragment.dig("bundle", "postBuildScripts")) + generated_post_build_scripts

  bundle_target_hash = {
    "type" => "bundle",
    "platform" => "macOS",
    "deploymentTarget" => "14.0",
    "configFiles" => {
      "Debug" => "Debug.xcconfig",
      "Nightly" => "Release.xcconfig",
      "Release" => "Release.xcconfig"
    },
    "sources" => bundle_sources,
    "dependencies" => [
      { "target" => "MacToolsPluginKit" },
      { "target" => core_target, "link" => true }
    ] + extra_bundle_dependencies + Array(fragment.dig("bundle", "dependencies")),
    "settings" => bundle_settings
  }
  bundle_target_hash["postBuildScripts"] = bundle_post_build_scripts unless bundle_post_build_scripts.empty?
  targets[bundle_target] = bundle_target_hash

  plugin_bundle_targets << bundle_target
  plugin_core_targets << core_target
  plugin_schemes[bundle_target] = {
    "build" => {
      "targets" => {
        "MacToolsPluginKit" => "all",
        core_target => "all",
        bundle_target => "all"
      }
        .merge(extra_scheme_targets.to_h { |target| [target, "all"] })
    },
    "profile" => { "config" => "Release" },
    "archive" => { "config" => "Release" }
  }
end

test_settings = {
  "base" => {
    "PRODUCT_BUNDLE_IDENTIFIER" => "$(BUNDLE_IDENTIFIER_PREFIX).mactoolsTests",
    "GENERATE_INFOPLIST_FILE" => "YES"
  },
  "configs" => {
    "Debug" => {
      "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/MacTools Dev.app/Contents/MacOS/MacTools Dev"
    },
    "Nightly" => {
      "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/MacTools Nightly.app/Contents/MacOS/MacTools Nightly"
    },
    "Release" => {
      "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/MacTools.app/Contents/MacOS/MacTools"
    }
  }
}
test_settings["base"]["SWIFT_INCLUDE_PATHS"] = test_include_paths.join(" ") unless test_include_paths.empty?
test_settings["base"]["OTHER_LDFLAGS"] = test_ldflags.join(" ") unless test_ldflags.empty?

targets["MacToolsTests"] = {
  "type" => "bundle.unit-test",
  "platform" => "macOS",
  "deploymentTarget" => "14.0",
  "sources" => [
    {
      "path" => relative_to_output_dir(File.join(repo_root, "Tests"), output_dir),
      "excludes" => ["Support/**"]
    },
    {
      "path" => relative_to_output_dir(File.join(repo_root, "Plugins"), output_dir),
      "includes" => ["*/Tests/**"]
    }
  ],
  "dependencies" => [
    { "target" => "MacTools" },
    { "target" => "MacToolsPluginKit" },
    { "target" => "MacToolsAppIntents" },
    { "target" => "MacToolsCLIProtocol" },
    { "target" => "MacToolsFileSystem" }
  ] + plugin_core_targets.map { |target| { "target" => target } },
  "settings" => test_settings
}

schemes = {
  "MacTools" => {
    "build" => {
      "targets" => {
        "MacToolsPluginKit" => "all",
        "MacToolsAppIntents" => "all",
        "MacToolsCLIProtocol" => "all",
        "MacToolsCLI" => "all",
        "MacToolsCLIBroker" => "all"
      }.merge(plugin_bundle_targets.to_h { |target| [target, "all"] })
        .merge(
          "MacTools" => "all",
          "MacToolsTests" => ["test"]
        )
    },
    "run" => { "config" => "Debug" },
    "test" => {
      "config" => "Debug",
      "environmentVariables" => {
        "MACTOOLS_DISABLE_TRACKPAD_LISTENER" => "1"
      },
      "targets" => [
        {
          "name" => "MacToolsTests",
          "parallelizable" => true
        }
      ]
    },
    "profile" => { "config" => "Release" },
    "archive" => { "config" => "Release" }
  },
  # Host-only scheme: builds the app and its non-plugin dependencies but no
  # plugin bundle targets. Used by 'make build-app' for the fast single-plugin
  # debug cycle so plugin bundles are not recompiled.
  "MacToolsAppHost" => {
    "build" => {
      "targets" => {
        "MacToolsPluginKit" => "all",
        "MacToolsAppIntents" => "all",
        "MacToolsCLIProtocol" => "all",
        "MacToolsCLI" => "all",
        "MacToolsCLIBroker" => "all",
        "MacTools" => "all"
      }
    },
    "run" => { "config" => "Debug" },
    "profile" => { "config" => "Release" },
    "archive" => { "config" => "Release" }
  },
  "MacToolsCLI" => {
    "build" => {
      "targets" => {
        "MacToolsCLIProtocol" => "all",
        "MacToolsCLI" => "all"
      }
    },
    "run" => { "config" => "Debug" },
    "profile" => { "config" => "Release" },
    "archive" => { "config" => "Release" }
  }
}.merge(plugin_schemes)

generated = +"# Generated by scripts/plugins/generate-plugin-project-config.rb. Do not edit.\n"
write_yaml(generated, "targets" => targets, "schemes" => schemes)

FileUtils.mkdir_p(File.dirname(output_path))
if !File.file?(output_path) || File.read(output_path) != generated
  File.write(output_path, generated)
end
