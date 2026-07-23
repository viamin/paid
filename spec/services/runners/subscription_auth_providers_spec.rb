# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::SubscriptionAuthProviders, :no_db do
  let(:claude_provider) { described_class.for_runner("claude") }

  describe ".for_runner" do
    it "returns a Claude provider adapter" do
      expect(claude_provider).not_to be_nil
      expect(claude_provider.remote_safe?).to be(true)
      expect(claude_provider.rotation_risk).to eq("server_refresh_only")
    end

    it "returns a Codex provider adapter that is not yet remote-safe (#2962)" do
      codex_provider = described_class.for_runner("codex")

      expect(codex_provider).not_to be_nil
      expect(codex_provider.remote_safe?).to be(false)
      expect(codex_provider.rotation_risk).to eq("container_may_rotate")
      expect(codex_provider.materialization_mode).to eq("native_file")
    end

    it "returns an explicit unsupported adapter for providers not yet extracted" do
      gemini_provider = described_class.for_runner("gemini")
      status = gemini_provider.status(secret: "anything")
      materialization = gemini_provider.materialize(secret: "anything")

      expect(status).to be_unsupported
      expect(materialization.supported?).to be(false)
    end
  end

  describe "Claude contract" do
    let(:managed_setup_token) { file_fixture("claude_managed_setup_token.txt").read.strip }
    let(:valid_credentials) { file_fixture("claude_credentials_valid.json").read }
    let(:expired_credentials) { file_fixture("claude_credentials_expired.json").read }
    let(:expired_unrefreshable_credentials) { file_fixture("claude_credentials_expired_unrefreshable.json").read }
    let(:unrefreshable_credentials) { file_fixture("claude_credentials_unrefreshable.json").read }
    let(:malformed_credentials) { file_fixture("claude_credentials_malformed.json").read }

    it "classifies a managed setup-token as valid and materializes CLAUDE_CODE_OAUTH_TOKEN" do
      status = claude_provider.status(secret: managed_setup_token)
      materialization = claude_provider.materialize(secret: managed_setup_token)

      expect(status).to be_valid
      expect(status.refreshable?).to be(false)
      expect(status.materialization_mode).to eq("env")
      expect(status.remote_safe?).to be(true)
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("env")
      expect(materialization.env).to eq("CLAUDE_CODE_OAUTH_TOKEN" => managed_setup_token)
      expect(materialization.files).to eq({})
    end

    it "classifies valid native credentials as valid and refreshable" do
      status = claude_provider.status(secret: valid_credentials)
      materialization = claude_provider.materialize(secret: valid_credentials)

      expect(status).to be_valid
      expect(status.refreshable?).to be(true)
      expect(status.expires_at).to eq(Time.parse("2100-01-01T00:00:00Z"))
      expect(status.materialization_mode).to eq("native_file")
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("native_file")
      expect(materialization.files.keys).to contain_exactly("/home/agent/.claude/.credentials.json")
      expect(materialization.files.fetch("/home/agent/.claude/.credentials.json")).to include("valid-access-token")
    end

    it "classifies expired native credentials as expired but still materializable when refreshable" do
      status = claude_provider.status(secret: expired_credentials)
      materialization = claude_provider.materialize(secret: expired_credentials)

      expect(status).to be_expired
      expect(status.refreshable?).to be(true)
      expect(status.error).to eq("expired")
      expect(status.materializable?).to be(true)
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("native_file")
      expect(materialization.files.keys).to contain_exactly("/home/agent/.claude/.credentials.json")
      expect(materialization.files.fetch("/home/agent/.claude/.credentials.json")).to include("expired-access-token")
    end

    it "classifies native credentials without a refresh token as unrefreshable but still valid" do
      status = claude_provider.status(secret: unrefreshable_credentials)

      expect(status).to be_valid
      expect(status.refreshable?).to be(false)
      expect(status.materializable?).to be(true)
    end

    it "classifies expired non-refreshable credentials as expired, present, but not materializable" do
      status = claude_provider.status(secret: expired_unrefreshable_credentials)

      expect(status).to be_expired
      expect(status.refreshable?).to be(false)
      # Not materializable (no refresh path), but still *present* so eligibility
      # classifies it as `:managed` with credential_state `:expired` rather than
      # silently falling back to `host_forwarded`.
      expect(status.materializable?).to be(false)
      expect(status).to be_present
    end

    it "treats any non-blank, non-unsupported credential as present for eligibility" do
      expect(claude_provider.status(secret: valid_credentials)).to be_present
      expect(claude_provider.status(secret: expired_credentials)).to be_present
      expect(claude_provider.status(secret: expired_unrefreshable_credentials)).to be_present
      expect(claude_provider.status(secret: malformed_credentials)).to be_present
      expect(claude_provider.status(secret: managed_setup_token)).to be_present
    end

    it "does not treat blank or unsupported credentials as present" do
      expect(claude_provider.status(secret: "")).not_to be_present
      expect(claude_provider.status(secret: "   ")).not_to be_present

      unsupported = described_class.for_runner("gemini").status(secret: "anything")
      expect(unsupported).not_to be_present
    end

    it "classifies malformed native credentials as malformed" do
      status = claude_provider.status(secret: malformed_credentials)
      materialization = claude_provider.materialize(secret: malformed_credentials)

      expect(status).to be_malformed
      expect(status.refreshable?).to be(false)
      expect(materialization.supported?).to be(false)
      expect(materialization.error).to eq("malformed")
    end

    it "exposes redacted metadata without secret values" do
      status = claude_provider.status(secret: valid_credentials)
      serialized = JSON.generate(status.redacted_metadata)

      expect(status.redacted_metadata).to eq(
        "materialized" => true,
        "kind" => "native_credentials_json",
        "has_refresh_token" => true,
        "has_expiry" => true,
        "subscription_type_present" => true,
        "scopes_present" => true
      )
      expect(serialized).not_to include("valid-access-token")
      expect(serialized).not_to include("valid-refresh-token")
    end
  end

  describe "Claude refresh contract" do
    let(:provisioner) { instance_double(Containers::Provision) }

    it "coerces a truthy non-true refresh outcome into performed: true" do
      # refresh_claude_subscription_credential! delegates to
      # refresh_claude_credentials_if_near_expiry! which returns nil on early
      # exits and an AuthAttemptRecorder::Result (never literal true) when a
      # refresh runs. The adapter must coerce that to a boolean so keep-warm
      # telemetry reports refreshed: true.
      allow(provisioner).to receive(:refresh_claude_subscription_credential!)
        .and_return(Runners::AuthAttemptRecorder::Result.new(recorded: true, error: nil))

      result = claude_provider.refresh(provisioner: provisioner)

      expect(result.supported?).to be(true)
      expect(result.performed?).to be(true)
      expect(result.reason).to eq("refreshed")
    end

    it "reports performed: false when no refresh runs" do
      allow(provisioner).to receive(:refresh_claude_subscription_credential!).and_return(nil)

      result = claude_provider.refresh(provisioner: provisioner)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("refresh_failed")
    end
  end

  describe "Codex contract" do
    let(:codex_provider) { described_class.for_runner("codex") }
    let(:valid_auth) { file_fixture("codex_auth_valid.json").read }
    let(:expired_auth) { file_fixture("codex_auth_expired.json").read }
    let(:unrefreshable_auth) { file_fixture("codex_auth_unrefreshable.json").read }
    let(:malformed_auth) { file_fixture("codex_auth_malformed.json").read }

    it "classifies valid native auth.json as valid and refreshable" do
      status = codex_provider.status(secret: valid_auth)
      materialization = codex_provider.materialize(secret: valid_auth)

      expect(status).to be_valid
      expect(status.refreshable?).to be(true)
      expect(status.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
      expect(status.materialization_mode).to eq("native_file")
      expect(status.remote_safe?).to be(false)
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("native_file")
      expect(materialization.files.keys).to contain_exactly("/home/agent/.codex/auth.json")
      expect(materialization.files.fetch("/home/agent/.codex/auth.json")).to include("managed-codex-refresh-token")
    end

    it "classifies expired native auth.json as expired but materializable when refreshable" do
      status = codex_provider.status(secret: expired_auth)
      materialization = codex_provider.materialize(secret: expired_auth)

      expect(status).to be_expired
      expect(status.refreshable?).to be(true)
      expect(status.error).to eq("expired")
      expect(status.materializable?).to be(true)
      expect(materialization.supported?).to be(true)
    end

    it "classifies auth.json without a refresh token as unrefreshable but still valid" do
      status = codex_provider.status(secret: unrefreshable_auth)

      expect(status).to be_valid
      expect(status.refreshable?).to be(false)
      expect(status.materializable?).to be(true)
    end

    it "treats non-blank Codex credentials as present for eligibility" do
      expect(codex_provider.status(secret: valid_auth)).to be_present
      expect(codex_provider.status(secret: expired_auth)).to be_present
      expect(codex_provider.status(secret: malformed_auth)).to be_present
    end

    it "does not treat blank or malformed tokens as present and rejects materialization" do
      expect(codex_provider.status(secret: "")).not_to be_present
      expect(codex_provider.status(secret: malformed_auth)).to be_present

      materialization = codex_provider.materialize(secret: malformed_auth)
      expect(materialization.supported?).to be(false)
      expect(materialization.error).to eq("malformed")
    end

    it "exposes redacted metadata without secret values" do
      status = codex_provider.status(secret: valid_auth)
      serialized = JSON.generate(status.redacted_metadata)

      expect(status.redacted_metadata["materialized"]).to be(true)
      expect(serialized).not_to include("managed-codex-refresh-token")
      expect(serialized).not_to include("eyJcodex-id-token")
      expect(serialized).not_to include("acc_managed-codex-001")
    end
  end

  describe "Codex refresh and harvest delegation" do
    let(:codex_provider) { described_class.for_runner("codex") }
    let(:provisioner) { instance_double(Containers::Provision) }

    it "delegates refresh to the provisioner and reports performed" do
      allow(provisioner).to receive(:refresh_codex_managed_credential!).and_return(true)

      result = codex_provider.refresh(provisioner: provisioner)

      expect(result.supported?).to be(true)
      expect(result.performed?).to be(true)
      expect(result.reason).to eq("refreshed")
    end

    it "reports refresh_skipped when the provisioner does not refresh" do
      allow(provisioner).to receive(:refresh_codex_managed_credential!).and_return(nil)

      result = codex_provider.refresh(provisioner: provisioner)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("refresh_skipped")
    end

    it "delegates harvest to the provisioner" do
      harvest_result = Runners::SubscriptionAuthProviders::Result.new(supported: true, performed: true, reason: "harvested")
      allow(provisioner).to receive(:harvest_codex_managed_credential!).and_return(harvest_result)

      expect(codex_provider.harvest(provisioner: provisioner)).to eq(harvest_result)
    end
  end
end
