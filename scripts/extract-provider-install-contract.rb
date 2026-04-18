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
rescue AgentHarness::ConfigurationError
  # Some providers (e.g., Codex) use the class-level installation_contract
  # instead of the generic registry method. Fall back to that API.
  begin
    provider_class = AgentHarness::Providers.const_get(provider.capitalize)
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

# Support both contract shapes:
# - Shell-based (Claude): {install: {command:, post_install_binary_path:}, supported_versions: {default:}}
# - npm-based (Codex):    {source: :npm, package:, install_command: [...], ...}
if contract[:source] == :npm
  puts "SOURCE=npm"
  puts "PACKAGE=#{contract[:package]}"
  puts "INSTALL_COMMAND=#{contract[:install_command]&.join(" ")}"
  puts "SUPPORTED_VERSION=#{contract[:version]}"
else
  puts "SOURCE=shell"
  puts "INSTALL_COMMAND=#{contract.dig(:install, :command)}"
  puts "POST_INSTALL_BINARY_PATH=#{contract.dig(:install, :post_install_binary_path)}"
  puts "SUPPORTED_VERSION=#{contract.dig(:supported_versions, :default)}"
end
