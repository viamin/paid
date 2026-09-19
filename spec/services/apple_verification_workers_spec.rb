# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationWorkers do
  it "rejects unsupported profile combinations before provisioning" do # @spec APPLE-WORKER-001
    profile = described_class::ProfileConstraints.new(platforms: [ "ios" ], xcode_version: ">= 26", capabilities: [ :build ])

    expect(profile.supports?(platform: :ios, required_capabilities: [ :build ])).to be(true)
    expect(profile.supports?(platform: :macos, required_capabilities: [ :build ])).to be(false)
    expect { described_class::ProfileConstraints.new(platforms: [ "ios" ], xcode_version: ">= 26", capabilities: [ :shell ]) }
      .to raise_error(described_class::UnsupportedCapability)
  end

  it "uses remote-execution lanes while rejecting host and credential fields" do # @spec APPLE-WORKER-002
    manifest = described_class::InputManifest.new(
      source: { "digest" => "sha256:#{'a' * 64}" }, verification: { "operations" => [ "build" ] }, profile: { "digest" => "sha256:#{'b' * 64}" },
      lanes: { "git" => [], "control_plane_api" => [], "object_storage" => [], "credentials" => [ { "lane" => "credentials", "kind" => "github_installation", "locator" => { "project_id" => 1 } } ] }
    )

    expect(manifest.as_json.dig("lanes", "credentials").first).not_to have_key("value")
    expect { described_class::InputManifest.new(source: { "host_path" => "/tmp/project" }, verification: {}, profile: {}, lanes: {}) }
      .to raise_error(described_class::InvalidManifest, /host_path/)
    expect { described_class::OutputManifest.new(attempt: {}, result: { "token" => "secret" }, artifacts: {}, lanes: {}) }
      .to raise_error(described_class::InvalidManifest, /token/)
  end

  it "rejects raw credentials and unknown fields in every manifest section" do # @spec APPLE-WORKER-002
    expect do
      described_class::InputManifest.new(
        source: { "digest" => "sha256:#{'a' * 64}" }, verification: { "api_key" => "raw-secret" }, profile: { "digest" => "sha256:#{'b' * 64}" }, lanes: {}
      )
    end.to raise_error(described_class::InvalidManifest, /api_key/)

    expect do
      described_class::InputManifest.new(
        source: { "digest" => "sha256:#{'a' * 64}", "credential_value" => "raw-secret" }, verification: {}, profile: { "digest" => "sha256:#{'b' * 64}" }, lanes: {}
      )
    end.to raise_error(described_class::InvalidManifest, /credential_value/)

    expect do
      described_class::InputManifest.new(
        source: { "digest" => "sha256:#{'a' * 64}" }, verification: {}, profile: { "digest" => "sha256:#{'b' * 64}" }, lanes: { "network" => [] }
      )
    end.to raise_error(described_class::InvalidManifest, /network/)
  end
end
