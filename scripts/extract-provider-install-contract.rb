#!/usr/bin/env ruby
# frozen_string_literal: true

# Extract install contract metadata from agent-harness for a given provider.
#
# Outputs key=value pairs suitable for shell eval or Docker build-arg injection.
# The build script and CI workflow use this to pass the agent-harness-owned
# install recipe into the Dockerfile without hardcoding provider-specific
# install logic in Paid.
#
# Usage:
#   bundle exec ruby scripts/extract-provider-install-contract.rb claude
#   eval "$(bundle exec ruby scripts/extract-provider-install-contract.rb claude)"

require "agent_harness"

provider = ARGV[0]
unless provider
  warn "Usage: #{$PROGRAM_NAME} <provider>"
  exit 1
end

# Cursor exposes install_metadata (artifact-based) rather than install_contract
# (command-based). Handle it separately so the build scripts can extract the
# artifact URL, checksum, and binary paths without installing agent-harness
# inside the Docker image.
if provider == "cursor"
  meta = AgentHarness::Providers::Cursor.install_metadata
  artifact = meta.dig(:checksum, :targets, :artifacts, "linux/x64")
  binary_name = meta.dig(:binary, :name)
  global_path = meta.dig(:binary, :suggested_global_path)
  unless artifact
    warn "No linux/x64 artifact found in Cursor install_metadata"
    exit 1
  end
  unless binary_name && global_path
    warn "No binary metadata found in Cursor install_metadata"
    exit 1
  end
  puts "ARTIFACT_URL=#{artifact[:url]}"
  puts "ARTIFACT_SHA256=#{artifact[:value]}"
  puts "BINARY_NAME=#{binary_name}"
  puts "GLOBAL_PATH=#{global_path}"
  exit 0
end

begin
  contract = AgentHarness.install_contract(provider.to_sym)
rescue AgentHarness::ConfigurationError
  # Some providers (e.g., Codex) use the class-level installation_contract
  # instead of the generic registry method. Fall back to that API.
  begin
    provider_class = AgentHarness::Providers.const_get(provider.split("_").map(&:capitalize).join)
    contract = provider_class.installation_contract
  rescue NameError, NoMethodError => e
    warn "No install contract found for provider: #{provider} (#{e.message})"
    exit 1
  end
end
unless contract
  warn "No install contract found for provider: #{provider}"
  exit 1
end

# Support all contract shapes:
# - Shell-based (Claude): {install: {command:, post_install_binary_path:}, supported_versions: {default:}}
# - npm-based (Codex):    {source: :npm, package:, install_command: [...], version:}
# - npm-nested (Kilocode): {source: {type: :npm, package:}, install_command: [...], default_version:}
# - Flat (Gemini):        {install_command_string:, default_version:}
source = contract[:source]
is_npm = source == :npm || (source.is_a?(Hash) && source[:type] == :npm)
if is_npm
  package = contract[:package] || (source.is_a?(Hash) && source[:package])
  puts "SOURCE=npm"
  puts "PACKAGE=#{package}"
  puts "INSTALL_COMMAND=#{contract[:install_command]&.join(" ")}"
  puts "SUPPORTED_VERSION=#{contract[:version] || contract[:default_version]}"
else
  install_command = contract.dig(:install, :command) || contract[:install_command_string]
  post_install_path = contract.dig(:install, :post_install_binary_path)
  supported_version = contract.dig(:supported_versions, :default) || contract[:default_version]

  puts "SOURCE=shell"
  puts "INSTALL_COMMAND=#{install_command}"
  puts "POST_INSTALL_BINARY_PATH=#{post_install_path}"
  puts "SUPPORTED_VERSION=#{supported_version}"
end
