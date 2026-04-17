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

contract = AgentHarness.install_contract(provider.to_sym)

puts "INSTALL_COMMAND=#{contract.dig(:install, :command)}"
puts "POST_INSTALL_BINARY_PATH=#{contract.dig(:install, :post_install_binary_path)}"
puts "SUPPORTED_VERSION=#{contract.dig(:supported_versions, :default)}"
