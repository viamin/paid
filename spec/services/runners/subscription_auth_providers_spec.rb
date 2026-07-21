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

    it "returns an explicit unsupported adapter for providers not yet extracted" do
      codex_provider = described_class.for_runner("codex")
      status = codex_provider.status(secret: "anything")
      materialization = codex_provider.materialize(secret: "anything")

      expect(status).to be_unsupported
      expect(materialization.supported?).to be(false)
      expect(codex_provider.remote_safe?).to be(false)
      expect(codex_provider.rotation_risk).to eq("container_may_rotate")
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

      unsupported = described_class.for_runner("codex").status(secret: "anything")
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
      # refresh_claude_credentials_if_near_expiry! returns nil on early exits
      # and an AuthAttemptRecorder::Result (never literal true) when a refresh
      # runs. The adapter must coerce that to a boolean so keep-warm telemetry
      # reports refreshed: true.
      allow(provisioner).to receive(:refresh_claude_credentials_if_near_expiry!)
        .and_return(Runners::AuthAttemptRecorder::Result.new(recorded: true, error: nil))

      result = claude_provider.refresh(provisioner: provisioner)

      expect(result.supported?).to be(true)
      expect(result.performed?).to be(true)
      expect(result.reason).to eq("refreshed")
    end

    it "reports performed: false when no refresh runs" do
      allow(provisioner).to receive(:refresh_claude_credentials_if_near_expiry!).and_return(nil)

      result = claude_provider.refresh(provisioner: provisioner)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("refresh_failed")
    end
  end
end
