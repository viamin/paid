# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::SubscriptionAuthProviders, :no_db do # @spec SUBSCRIPTION-RUNNER-AUTH-001 # @spec SUBSCRIPTION-RUNNER-AUTH-002
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

    it "returns OpenCode and OMP provider adapters that are not yet remote-safe" do
      opencode_provider = described_class.for_runner("opencode")
      omp_provider = described_class.for_runner("omp")

      expect(opencode_provider.remote_safe?).to be(false)
      expect(opencode_provider.rotation_risk).to eq("container_may_rotate")
      expect(opencode_provider.materialization_mode).to eq("native_file")

      expect(omp_provider.remote_safe?).to be(false)
      expect(omp_provider.rotation_risk).to eq("container_may_rotate")
      expect(omp_provider.materialization_mode).to eq("native_file")
    end

    it "returns a Gemini provider adapter that is remote-safe (#2964)" do
      gemini_provider = described_class.for_runner("gemini")

      expect(gemini_provider).not_to be_nil
      expect(gemini_provider.remote_safe?).to be(true)
      expect(gemini_provider.rotation_risk).to eq("container_may_rotate")
      expect(gemini_provider.materialization_mode).to eq("native_file")
    end

    it "returns a Copilot provider adapter that is remote-safe (#2964)" do
      copilot_provider = described_class.for_runner("copilot")

      expect(copilot_provider).not_to be_nil
      expect(copilot_provider.remote_safe?).to be(true)
      expect(copilot_provider.rotation_risk).to eq("container_may_rotate")
      expect(copilot_provider.materialization_mode).to eq("native_file")
    end

    it "returns an explicit unsupported adapter for unknown providers" do
      unknown_provider = described_class.for_runner("unknown-provider")
      expect(unknown_provider).to be_nil
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

      blank = described_class.for_runner("gemini").status(secret: "")
      expect(blank).not_to be_present
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

  describe "OpenCode contract" do
    let(:opencode_provider) { described_class.for_runner("opencode") }
    let(:valid_auth) { file_fixture("codex_auth_valid.json").read }
    let(:provisioner) { instance_double(Containers::Provision) }

    it "materializes the OpenAI auth payload to OpenCode's auth.json path" do
      status = opencode_provider.status(secret: valid_auth)
      materialization = opencode_provider.materialize(secret: valid_auth)
      fixture_payload = JSON.parse(valid_auth)
      fixture_tokens = fixture_payload.fetch("tokens")

      expect(status).to be_valid
      expect(materialization.supported?).to be(true)
      expect(materialization.files.keys).to contain_exactly("/home/agent/.local/share/opencode/auth.json")
      payload = JSON.parse(materialization.files.fetch("/home/agent/.local/share/opencode/auth.json"))
      expect(payload).to eq(
        "openai" => {
          "type" => "oauth",
          "access" => fixture_tokens.fetch("access_token"),
          "refresh" => fixture_tokens.fetch("refresh_token"),
          "expires" => 4_102_444_800_000,
          "accountId" => "acc_managed-codex-001"
        }
      )
    end

    it "omits expires when the managed auth payload has no expiry" do
      auth_without_expiry = JSON.parse(valid_auth)
      auth_without_expiry.fetch("tokens").delete("expires_at")
      auth_without_expiry.fetch("tokens")["access_token"] = "opaque-access-token"

      materialization = opencode_provider.materialize(secret: JSON.generate(auth_without_expiry))
      payload = JSON.parse(materialization.files.fetch("/home/agent/.local/share/opencode/auth.json"))

      expect(payload).to eq(
        "openai" => {
          "type" => "oauth",
          "access" => auth_without_expiry.fetch("tokens").fetch("access_token"),
          "refresh" => auth_without_expiry.fetch("tokens").fetch("refresh_token"),
          "accountId" => "acc_managed-codex-001"
        }
      )
    end

    it "delegates refresh to the provisioner and reports performed" do
      allow(provisioner).to receive(:refresh_opencode_managed_credential!).and_return(true)

      result = opencode_provider.refresh(provisioner: provisioner)

      expect(result.supported?).to be(true)
      expect(result.performed?).to be(true)
      expect(result.reason).to eq("refreshed")
    end

    it "reports refresh_skipped when the provisioner does not refresh" do
      allow(provisioner).to receive(:refresh_opencode_managed_credential!).and_return(nil)

      result = opencode_provider.refresh(provisioner: provisioner)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("refresh_skipped")
    end

    it "delegates harvest to the provisioner" do
      harvest_result = Runners::SubscriptionAuthProviders::Result.new(supported: true, performed: true, reason: "harvested")
      allow(provisioner).to receive(:harvest_opencode_managed_credential!).and_return(harvest_result)

      expect(opencode_provider.harvest(provisioner: provisioner)).to eq(harvest_result)
    end
  end

  describe "OMP contract" do
    let(:omp_provider) { described_class.for_runner("omp") }
    let(:valid_credentials) { file_fixture("claude_credentials_valid.json").read }

    it "materializes a Claude native credential as an omp auth-broker import file" do
      status = omp_provider.status(secret: valid_credentials)
      materialization = omp_provider.materialize(secret: valid_credentials)

      expect(status).to be_valid
      expect(materialization.supported?).to be(true)
      expect(materialization.files.keys).to contain_exactly("/home/agent/.local/share/omp/paid-auth-import.json")
      payload = JSON.parse(materialization.files.fetch("/home/agent/.local/share/omp/paid-auth-import.json"))
      expect(payload["type"]).to eq("claude")
      expect(payload["access_token"]).to eq("valid-access-token")
      expect(payload["refresh_token"]).to eq("valid-refresh-token")
      expect(payload["expired"]).to eq("2100-01-01T00:00:00Z")
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

  describe "Gemini contract" do
    let(:gemini_provider) { described_class.for_runner("gemini") }
    let(:valid_creds) { file_fixture("gemini_oauth_creds.json").read }
    let(:unrefreshable_creds) do
      JSON.generate("access_token" => "ya29.access-only", "token_type" => "Bearer", "expiry_date" => 4102444800000)
    end
    let(:expired_creds) do
      JSON.generate("access_token" => "ya29.expired", "refresh_token" => "1//refresh",
        "token_type" => "Bearer", "expiry_date" => 1)
    end

    it "classifies valid oauth credentials as valid and refreshable" do
      status = gemini_provider.status(secret: valid_creds)
      materialization = gemini_provider.materialize(secret: valid_creds)

      expect(status).to be_valid
      expect(status.refreshable?).to be(true)
      expect(status.expires_at).to eq(Time.at(4_102_444_800, in: "UTC"))
      expect(status.materialization_mode).to eq("native_file")
      expect(status.remote_safe?).to be(true)
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("native_file")
      expect(materialization.files.keys).to contain_exactly("/home/agent/.gemini/oauth_creds.json")
      expect(materialization.files.fetch("/home/agent/.gemini/oauth_creds.json")).to include("managed-gemini-access-token")
    end

    it "drops host-only fields from the materialized config" do
      materialization = gemini_provider.materialize(secret: valid_creds)

      expect(materialization.files.fetch("/home/agent/.gemini/oauth_creds.json"))
        .not_to include("should-not-leak-into-container")
    end

    it "classifies expired oauth credentials as expired but materializable when refreshable" do
      status = gemini_provider.status(secret: expired_creds)
      materialization = gemini_provider.materialize(secret: expired_creds)

      expect(status).to be_expired
      expect(status.refreshable?).to be(true)
      expect(status.materializable?).to be(true)
      expect(materialization.supported?).to be(true)
    end

    it "classifies oauth credentials without a refresh token as unrefreshable but still valid" do
      status = gemini_provider.status(secret: unrefreshable_creds)

      expect(status).to be_valid
      expect(status.refreshable?).to be(false)
      expect(status.materializable?).to be(true)
    end

    it "treats non-blank valid Gemini credentials as present for eligibility" do
      expect(gemini_provider.status(secret: valid_creds)).to be_present
      expect(gemini_provider.status(secret: expired_creds)).to be_present
    end

    it "does not treat blank or non-oauth payloads as present" do
      expect(gemini_provider.status(secret: "")).not_to be_present
      expect(gemini_provider.status(secret: "{\"unexpected\":true}")).not_to be_present
    end

    it "exposes redacted metadata without secret values" do
      status = gemini_provider.status(secret: valid_creds)
      serialized = JSON.generate(status.redacted_metadata)

      expect(status.redacted_metadata["materialized"]).to be(true)
      expect(serialized).not_to include("managed-gemini-access-token")
      expect(serialized).not_to include("managed-gemini-refresh-token")
    end

    it "returns unsupported refresh and harvest until the provider lifecycle lands" do
      provisioner = instance_double(Containers::Provision)

      refresh_result = gemini_provider.refresh(provisioner: provisioner)
      harvest_result = gemini_provider.harvest(provisioner: provisioner)

      expect(refresh_result.supported?).to be(false)
      expect(harvest_result.supported?).to be(false)
    end
  end

  describe "Copilot contract" do
    let(:copilot_provider) { described_class.for_runner("copilot") }
    let(:valid_config) { file_fixture("copilot_config.json").read }
    let(:unrefreshable_config) do
      JSON.generate("oauth_token" => "tid=copilot-oauth;exp=4102444800")
    end
    let(:expired_config) do
      JSON.generate("oauth_token" => "tid=copilot-oauth;exp=1",
        "refresh_token" => "copilot-refresh", "expires_at" => "2000-01-01T00:00:00Z")
    end

    it "classifies valid config as valid and refreshable" do
      status = copilot_provider.status(secret: valid_config)
      materialization = copilot_provider.materialize(secret: valid_config)

      expect(status).to be_valid
      expect(status.refreshable?).to be(true)
      expect(status.expires_at).to eq(Time.parse("2100-01-01T00:00:00Z"))
      expect(status.materialization_mode).to eq("native_file")
      expect(status.remote_safe?).to be(true)
      expect(materialization.supported?).to be(true)
      expect(materialization.mode).to eq("native_file")
      expect(materialization.files.keys).to contain_exactly("/home/agent/.copilot/config.json")
      expect(materialization.files.fetch("/home/agent/.copilot/config.json")).to include("managed-copilot-oauth-token")
    end

    it "drops host-only fields from the materialized config" do
      materialization = copilot_provider.materialize(secret: valid_config)

      expect(materialization.files.fetch("/home/agent/.copilot/config.json"))
        .not_to include("should-not-leak-into-container")
    end

    it "classifies expired config as expired but materializable when refreshable" do
      status = copilot_provider.status(secret: expired_config)
      materialization = copilot_provider.materialize(secret: expired_config)

      expect(status).to be_expired
      expect(status.refreshable?).to be(true)
      expect(status.materializable?).to be(true)
      expect(materialization.supported?).to be(true)
    end

    it "classifies config without a refresh token as unrefreshable but still valid" do
      status = copilot_provider.status(secret: unrefreshable_config)

      expect(status).to be_valid
      expect(status.refreshable?).to be(false)
      expect(status.materializable?).to be(true)
    end

    it "treats non-blank valid Copilot credentials as present for eligibility" do
      expect(copilot_provider.status(secret: valid_config)).to be_present
      expect(copilot_provider.status(secret: expired_config)).to be_present
    end

    it "does not treat blank or non-copilot payloads as present" do
      expect(copilot_provider.status(secret: "")).not_to be_present
      expect(copilot_provider.status(secret: "{\"unexpected\":true}")).not_to be_present
    end

    it "exposes redacted metadata without secret values" do
      status = copilot_provider.status(secret: valid_config)
      serialized = JSON.generate(status.redacted_metadata)

      expect(status.redacted_metadata["materialized"]).to be(true)
      expect(serialized).not_to include("managed-copilot-oauth-token")
      expect(serialized).not_to include("managed-copilot-refresh-token")
    end

    it "returns unsupported refresh and harvest until the provider lifecycle lands" do
      provisioner = instance_double(Containers::Provision)

      refresh_result = copilot_provider.refresh(provisioner: provisioner)
      harvest_result = copilot_provider.harvest(provisioner: provisioner)

      expect(refresh_result.supported?).to be(false)
      expect(harvest_result.supported?).to be(false)
    end
  end
end
