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
  unless artifact
    warn "No linux/x64 artifact found in Cursor install_metadata"
    exit 1
  end
  puts "ARTIFACT_URL=#{artifact[:url]}"
  puts "ARTIFACT_SHA256=#{artifact[:value]}"
  puts "BINARY_NAME=#{meta.dig(:binary, :name)}"
  puts "GLOBAL_PATH=#{meta.dig(:binary, :suggested_global_path)}"
  exit 0
end

begin
  contract = AgentHarness.install_contract(provider.to_sym)
rescue AgentHarness::ConfigurationError => e
  warn "No install contract found for provider: #{provider} (#{e.message})"
  exit 1
end
unless contract
  warn "No install contract found for provider: #{provider}"
  exit 1
end

puts "INSTALL_COMMAND=#{contract.dig(:install, :command)}"
puts "POST_INSTALL_BINARY_PATH=#{contract.dig(:install, :post_install_binary_path)}"
puts "SUPPORTED_VERSION=#{contract.dig(:supported_versions, :default)}"
