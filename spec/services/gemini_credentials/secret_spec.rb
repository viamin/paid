# frozen_string_literal: true

require "rails_helper"
require "json"

RSpec.describe GeminiCredentials::Secret do
  let(:fixture_path) { file_fixture("gemini_oauth_creds.json").to_s }
  let(:fixture_payload) { JSON.parse(File.read(fixture_path)) }

  describe ".parse" do
    it "parses a Gemini oauth_creds payload from a fixture" do
      parsed = described_class.parse(File.read(fixture_path))

      expect(parsed).to be_oauth_credentials
      expect(parsed.access_token).to eq(fixture_payload["access_token"])
      expect(parsed.refresh_token).to eq(fixture_payload["refresh_token"])
      expect(parsed.scope).to include("cloud-platform")
      expect(parsed.token_type).to eq("Bearer")
    end

    it "returns blank for an empty secret" do
      parsed = described_class.parse("")

      expect(parsed).to be_blank
      expect(parsed.access_token).to be_nil
    end

    it "returns blank for a malformed secret" do
      expect(described_class.parse("not-json")).to be_blank
    end

    it "returns blank for a payload without OAuth credentials" do
      expect(described_class.parse(JSON.generate("foo" => "bar"))).to be_blank
    end

    it "normalizes camelCased credential keys" do
      parsed = described_class.parse(JSON.generate(
        "accessToken" => "ya29.camel",
        "refreshToken" => "1//camel",
        "expiryDate" => 4102444800000
      ))

      expect(parsed).to be_oauth_credentials
      expect(parsed.access_token).to eq("ya29.camel")
      expect(parsed.refresh_token).to eq("1//camel")
    end

    it "parses expiry_date epoch milliseconds into a Time" do
      parsed = described_class.parse(File.read(fixture_path))

      expect(parsed.expiry_date_ms).to eq(4102444800000)
      expect(parsed.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
    end
  end

  describe "#oauth_creds_json (materializer)" do
    it "generates the minimal native oauth_creds.json the Gemini CLI reads" do
      parsed = described_class.parse(File.read(fixture_path))
      materialized = JSON.parse(parsed.oauth_creds_json)

      expect(materialized).to eq(
        "access_token" => fixture_payload["access_token"],
        "refresh_token" => fixture_payload["refresh_token"],
        "scope" => fixture_payload["scope"],
        "token_type" => "Bearer",
        "expiry_date" => fixture_payload["expiry_date"]
      )
    end

    it "drops host-only fields that the container does not need" do
      parsed = described_class.parse(File.read(fixture_path))
      materialized = parsed.oauth_creds_json

      expect(materialized).not_to include("extra_host_only_field")
    end

    it "returns nil when the secret is blank" do
      expect(described_class.parse("").oauth_creds_json).to be_nil
    end
  end

  describe "#redacted_metadata (secret safety)" do
    it "exposes only non-secret context" do
      parsed = described_class.parse(File.read(fixture_path))
      metadata = parsed.redacted_metadata

      expect(metadata).to eq(
        "materialized" => true,
        "has_refresh_token" => true,
        "has_expiry" => true,
        "scope_present" => true
      )
    end

    it "never includes the access token, refresh token, or bearer material" do
      parsed = described_class.parse(File.read(fixture_path))
      serialized = JSON.generate(parsed.redacted_metadata)

      expect(serialized).not_to include(fixture_payload["access_token"])
      expect(serialized).not_to include(fixture_payload["refresh_token"])
      expect(serialized).not_to match(/Bearer\s+/)
    end

    it "is safe to persist through runner auth telemetry" do
      parsed = described_class.parse(File.read(fixture_path))
      metadata = parsed.redacted_metadata.merge("source" => "managed_native_config")

      expect(metadata.keys.map(&:to_s) & RunnerAuthAttempt::FORBIDDEN_METADATA_KEYS).to be_empty
      expect(metadata.values.any? { |value| RunnerAuthAttempt.secret_like?(value) }).to be(false)
    end
  end
end
