# frozen_string_literal: true

require "rails_helper"
require "json"

RSpec.describe CopilotCredentials::Secret do
  let(:fixture_path) { file_fixture("copilot_config.json").to_s }
  let(:fixture_payload) { JSON.parse(File.read(fixture_path)) }

  describe ".parse" do
    it "parses a Copilot config payload from a fixture" do
      parsed = described_class.parse(File.read(fixture_path))

      expect(parsed).to be_copilot_config
      expect(parsed.oauth_token).to eq(fixture_payload["oauth_token"])
      expect(parsed.refresh_token).to eq(fixture_payload["refresh_token"])
    end

    it "returns blank for an empty secret" do
      parsed = described_class.parse("")

      expect(parsed).to be_blank
      expect(parsed.oauth_token).to be_nil
    end

    it "returns blank for a malformed secret" do
      expect(described_class.parse("not-json")).to be_blank
    end

    it "returns blank for a payload without an OAuth token" do
      expect(described_class.parse(JSON.generate("foo" => "bar"))).to be_blank
    end

    it "recognizes token under any historically used key" do
      %w[oauth_token oauthToken token].each do |key|
        parsed = described_class.parse(JSON.generate(key => "copilot-token"))
        expect(parsed.oauth_token).to eq("copilot-token")
      end
    end

    it "recognizes a token nested under auth" do
      parsed = described_class.parse(JSON.generate("auth" => { "token" => "nested-token" }))

      expect(parsed).to be_copilot_config
      expect(parsed.oauth_token).to eq("nested-token")
    end

    it "parses expires_at into a Time" do
      parsed = described_class.parse(File.read(fixture_path))

      expect(parsed.expires_at).to eq(Time.parse("2100-01-01T00:00:00Z"))
    end
  end

  describe "#config_json (materializer)" do
    it "generates the minimal native config.json the Copilot CLI reads" do
      parsed = described_class.parse(File.read(fixture_path))
      materialized = JSON.parse(parsed.config_json)

      expect(materialized).to eq(
        "oauth_token" => fixture_payload["oauth_token"],
        "refresh_token" => fixture_payload["refresh_token"],
        "expires_at" => "2100-01-01T00:00:00Z"
      )
    end

    it "drops host-only fields that the container does not need" do
      parsed = described_class.parse(File.read(fixture_path))

      expect(parsed.config_json).not_to include("extra_host_only_field")
      expect(parsed.config_json).not_to include(fixture_payload["user"])
    end

    it "materializes config with only the oauth token when no extras are present" do
      parsed = described_class.parse(JSON.generate("oauth_token" => "lonely-token"))
      materialized = JSON.parse(parsed.config_json)

      expect(materialized).to eq("oauth_token" => "lonely-token")
    end

    it "returns nil when the secret is blank" do
      expect(described_class.parse("").config_json).to be_nil
    end
  end

  describe "#redacted_metadata (secret safety)" do
    it "exposes only non-secret context" do
      parsed = described_class.parse(File.read(fixture_path))
      metadata = parsed.redacted_metadata

      expect(metadata).to eq(
        "materialized" => true,
        "has_refresh_token" => true,
        "has_expiry" => true
      )
    end

    it "never includes the OAuth token or refresh token" do
      parsed = described_class.parse(File.read(fixture_path))
      serialized = JSON.generate(parsed.redacted_metadata)

      expect(serialized).not_to include(fixture_payload["oauth_token"])
      expect(serialized).not_to include(fixture_payload["refresh_token"])
    end

    it "is safe to persist through runner auth telemetry" do
      parsed = described_class.parse(File.read(fixture_path))
      metadata = parsed.redacted_metadata.merge("source" => "managed_native_config")

      expect(metadata.keys.map(&:to_s) & RunnerAuthAttempt::FORBIDDEN_METADATA_KEYS).to be_empty
      expect(metadata.values.any? { |value| RunnerAuthAttempt.secret_like?(value) }).to be(false)
    end
  end
end
