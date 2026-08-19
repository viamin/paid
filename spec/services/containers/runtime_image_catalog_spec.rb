# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::RuntimeImageCatalog do
  around do |example|
    original = ENV.fetch(described_class::ENV_DIGESTS_KEY, :unset)
    ENV.delete(described_class::ENV_DIGESTS_KEY)
    example.run
  ensure
    if original == :unset
      ENV.delete(described_class::ENV_DIGESTS_KEY)
    else
      ENV[described_class::ENV_DIGESTS_KEY] = original
    end
  end

  describe "#identity_for" do
    let(:profile_config) do
      {
        "registry" => "ghcr.io",
        "repository" => "acme/paid-agent",
        "profiles" => {
          "paid-agent:latest" => {
            "default_reference" => "base-amd64-2026-08-17",
            "identities" => {
              "base-amd64-2026-08-17" => {
                "digest" => "sha256:#{'1' * 64}",
                "architecture" => "amd64",
                "status" => "active"
              }
            }
          }
        }
      }
    end

    it "loads profiles from config when the env var is unset" do
      catalog = described_class.new(profile_config)

      identity = catalog.identity_for(requested_image: "paid-agent:latest")

      expect(identity.digest).to eq("sha256:#{'1' * 64}")
    end

    it "merges env-provided profiles into config profiles" do
      ENV[described_class::ENV_DIGESTS_KEY] = JSON.dump(
        "paid-agent:go" => {
          "digest" => "sha256:#{'2' * 64}",
          "architecture" => "amd64"
        }
      )
      catalog = described_class.new(profile_config)

      identity = catalog.identity_for(requested_image: "paid-agent:go")

      expect(identity.digest).to eq("sha256:#{'2' * 64}")
      expect(identity.repository).to eq("acme/paid-agent")
    end

    it "raises a descriptive error when the env var holds valid JSON that is not an object" do
      ENV[described_class::ENV_DIGESTS_KEY] = JSON.dump([ "paid-agent:latest" ])
      catalog = described_class.new(profile_config)

      expect { catalog.identity_for(requested_image: "paid-agent:missing") }
        .to raise_error(
          described_class::Error,
          /#{described_class::ENV_DIGESTS_KEY} must be a JSON object/
        )
    end

    it "raises a descriptive error when the env var holds invalid JSON" do
      ENV[described_class::ENV_DIGESTS_KEY] = "{not-json"
      catalog = described_class.new(profile_config)

      expect { catalog.identity_for(requested_image: "paid-agent:missing") }
        .to raise_error(
          described_class::Error,
          /Invalid #{described_class::ENV_DIGESTS_KEY}/
        )
    end
  end
end
