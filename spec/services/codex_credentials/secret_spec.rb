# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodexCredentials::Secret, :no_db do
  let(:valid_auth) { file_fixture("codex_auth_valid.json").read }
  let(:expired_auth) { file_fixture("codex_auth_expired.json").read }
  let(:unrefreshable_auth) { file_fixture("codex_auth_unrefreshable.json").read }
  let(:malformed_auth) { file_fixture("codex_auth_malformed.json").read }

  describe ".parse" do
    it "parses a native Codex auth.json payload" do
      parsed = described_class.parse(valid_auth)

      expect(parsed).to be_codex_auth
      expect(parsed.access_token).to start_with("eyJhbGci")
      expect(parsed.refresh_token).to eq("v1.managed-codex-refresh-token")
      expect(parsed.id_token).to eq("eyJcodex-id-token")
      expect(parsed.account_id).to eq("acc_managed-codex-001")
      expect(parsed).to be_refreshable
    end

    it "derives expiry from the access token JWT exp claim" do
      parsed = described_class.parse(valid_auth)

      expect(parsed.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
    end

    it "reports a past expiry for an expired access token" do
      parsed = described_class.parse(expired_auth)

      expect(parsed.expires_at).to eq(Time.at(1, in: "UTC"))
      expect(parsed.expires_at).to be <= Time.current
    end

    it "reports non-refreshable when the refresh token is absent" do
      parsed = described_class.parse(unrefreshable_auth)

      expect(parsed).not_to be_refreshable
    end

    it "treats a malformed payload as blank" do
      parsed = described_class.parse(malformed_auth)

      expect(parsed).to be_blank
      expect(parsed).not_to be_codex_auth
    end

    it "treats blank and unparseable input as blank" do
      expect(described_class.parse("")).to be_blank
      expect(described_class.parse("   ")).to be_blank
      expect(described_class.parse("not-json")).to be_blank
    end
  end

  describe "#auth_json" do
    it "materializes only the native fields the Codex CLI needs" do
      parsed = described_class.parse(valid_auth)
      materialized = JSON.parse(parsed.auth_json)

      expect(materialized["tokens"]["access_token"]).to start_with("eyJhbGci")
      expect(materialized["tokens"]["refresh_token"]).to eq("v1.managed-codex-refresh-token")
      expect(materialized["tokens"]["id_token"]).to eq("eyJcodex-id-token")
      expect(materialized["tokens"]["account_id"]).to eq("acc_managed-codex-001")
      expect(materialized["OPENAI_API_KEY"]).to be_nil
      expect(materialized["last_refresh"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "drops unrelated host-only fields" do
      enriched = JSON.parse(valid_auth)
      enriched["tokens"]["secret_host_field"] = "should-not-leak"
      enriched["host_only_meta"] = "should-not-leak"
      parsed = described_class.parse(JSON.generate(enriched))
      materialized = JSON.parse(parsed.auth_json)

      expect(materialized).not_to have_key("host_only_meta")
      expect(materialized["tokens"]).not_to have_key("secret_host_field")
    end

    it "returns nil for blank input" do
      expect(described_class.parse("").auth_json).to be_nil
    end
  end

  describe "#redacted_metadata" do
    it "exposes only non-secret context" do
      parsed = described_class.parse(valid_auth)
      serialized = JSON.generate(parsed.redacted_metadata)

      expect(parsed.redacted_metadata).to eq(
        "materialized" => true,
        "has_refresh_token" => true,
        "has_expiry" => true,
        "has_account_id" => true,
        "has_openai_api_key" => false
      )
      expect(serialized).not_to include("managed-codex-refresh-token")
      expect(serialized).not_to include("eyJcodex-id-token")
      expect(serialized).not_to include("acc_managed-codex-001")
    end

    it "reports materialized: false for blank input" do
      expect(described_class.parse("").redacted_metadata).to eq("materialized" => false)
    end
  end
end
