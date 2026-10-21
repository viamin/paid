# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("scripts/lib/toolchain_pins")

RSpec.describe ToolchainPins, :no_db do
  # @spec TOOLCHAIN-PIN-041
  it "keeps every build-time Ruby source pin aligned with .tool-versions" do
    version = Rails.root.join(".tool-versions").read[/^ruby\s+(.+)$/, 1]
    production = Rails.root.join("Dockerfile").read[/^ARG RUBY_VERSION=(.+)$/, 1]
    agent = Rails.root.join("docker/agent/Dockerfile").read[/RUN RUBY_VERSION=([^\s]+) /, 1]

    expect(version).to be_present
    expect(production).to eq(version)
    expect(agent).to eq(version)
  end

  # @spec TOOLCHAIN-PIN-041
  it "verifies the agent Ruby source and validates the devcontainer runtime" do
    agent = Rails.root.join("docker/agent/Dockerfile").read
    devcontainer = Rails.root.join(".devcontainer/Dockerfile").read

    expect(agent).to include('echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c -')
    expect(devcontainer).to include("ruby -e 'print RUBY_VERSION'")
    expect(devcontainer).to include(".tool-versions")
  end
end
