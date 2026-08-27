# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpencodeCredentials::Secret, :no_db do
  describe ".parse" do
    it "preserves expiry when converting OpenCode auth into canonical Codex auth" do
      payload = JSON.generate(
        "openai" => {
          "type" => "oauth",
          "access" => "opencode-access-token",
          "refresh" => "opencode-refresh-token",
          "expires" => 4_102_444_800_000,
          "accountId" => "acc_managed-codex-001"
        }
      )

      parsed = described_class.parse(payload)
      canonical = CodexCredentials::Secret.parse(parsed.codex_auth_json)

      expect(parsed).to be_opencode_auth
      expect(parsed.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
      expect(canonical).to be_codex_auth
      expect(canonical.refresh_token).to eq("opencode-refresh-token")
      expect(canonical.account_id).to eq("acc_managed-codex-001")
      expect(canonical.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
    end
  end
end
