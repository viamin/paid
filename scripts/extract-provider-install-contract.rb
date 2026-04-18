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

# Contracts may use nested (:install -> :command) or flat (:install_command_string)
# structures depending on the provider. Support both layouts so the script works
# across all providers without provider-specific branching.
install_command = contract.dig(:install, :command) || contract[:install_command_string]
post_install_path = contract.dig(:install, :post_install_binary_path)
supported_version = contract.dig(:supported_versions, :default) || contract[:default_version]

puts "INSTALL_COMMAND=#{install_command}"
puts "POST_INSTALL_BINARY_PATH=#{post_install_path}"
puts "SUPPORTED_VERSION=#{supported_version}"
