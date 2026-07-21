# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::SubscriptionAuthEligibility, :no_db do
  let(:host_path_backend) do
    instance_double(Containers::Backends::Base, identifier: "local", remote?: false, supports_host_paths?: true)
  end

  let(:remote_backend) do
    instance_double(Containers::Backends::RemoteDocker, identifier: "elguapo", remote?: true, supports_host_paths?: false)
  end

  def auth_source(runner_key:, auth_mode:, credential_state: nil)
    described_class::AuthSource.new(runner_key: runner_key, auth_mode: auth_mode, credential_state: credential_state)
  end

  describe "host-forwarded subscription auth" do
    it "is eligible on a host-path-capable backend" do
      result = described_class.call(
        backend: host_path_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :host_forwarded)
      )

      expect(result).to be_eligible
      expect(result.reason).to be_nil
      expect(result.auth_mode).to eq(:host_forwarded)
    end

    it "is rejected with requires_host_bind_mount on a remote backend" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :host_forwarded)
      )

      expect(result).to be_ineligible
      expect(result.reason).to eq(:requires_host_bind_mount)
      expect(result.message).to include("elguapo").and include("host bind mounts")
    end

    it "directs Claude operators toward the managed credential flow" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :host_forwarded)
      )

      expect(result.message).to include("managed claude credential")
    end

    it "directs Codex operators toward a host-path backend (no managed adapter yet)" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :host_forwarded)
      )

      expect(result.message).not_to include("managed codex credential")
      expect(result.message).to include("host-path-capable backend")
    end
  end

  describe "managed RunnerCredential auth" do
    it "is eligible on a remote backend when the materializer is remote-safe and active" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :managed, credential_state: :active)
      )

      expect(result).to be_eligible
      expect(result.auth_mode).to eq(:managed)
    end

    it "is eligible on a remote backend for Gemini and Copilot managed credentials (#2964)" do
      %w[gemini copilot].each do |runner_key|
        result = described_class.call(
          backend: remote_backend,
          auth_source: auth_source(runner_key: runner_key, auth_mode: :managed, credential_state: :active)
        )

        expect(result).to be_eligible
        expect(result.auth_mode).to eq(:managed)
      end
    end

    it "directs Gemini and Copilot host-forwarded operators to the managed credential flow" do
      %w[gemini copilot].each do |runner_key|
        result = described_class.call(
          backend: remote_backend,
          auth_source: auth_source(runner_key: runner_key, auth_mode: :host_forwarded)
        )

        expect(result).to be_ineligible
        expect(result.reason).to eq(:requires_host_bind_mount)
        expect(result.message).to include("managed #{runner_key} credential")
      end
    end

    it "is rejected with credential_expired when the managed credential is expired" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :managed, credential_state: :expired)
      )

      expect(result.reason).to eq(:credential_expired)
    end

    it "treats a revoked managed credential as credential_expired" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :managed, credential_state: :revoked)
      )

      expect(result.reason).to eq(:credential_expired)
    end

    it "is rejected with credential_refresh_failed when refresh failed" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :managed, credential_state: :refresh_failed)
      )

      expect(result.reason).to eq(:credential_refresh_failed)
    end

    it "is rejected with provider_materializer_missing on a remote backend when no remote-safe materializer exists" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :managed, credential_state: :active)
      )

      expect(result.reason).to eq(:provider_materializer_missing)
      expect(result.message).to include("no remote-safe materializer")
    end

    it "remains eligible on a host-path-capable backend even without a remote-safe materializer" do
      result = described_class.call(
        backend: host_path_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :managed, credential_state: :active)
      )

      expect(result).to be_eligible
    end
  end

  describe "API-key/proxy auth" do
    it "is eligible when the proxy is reachable" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :api_key_proxy),
        proxy_reachable: true
      )

      expect(result).to be_eligible
      expect(result.auth_mode).to eq(:api_key_proxy)
    end

    it "is rejected with remote_proxy_unreachable when the proxy is not reachable" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "codex", auth_mode: :api_key_proxy),
        proxy_reachable: false
      )

      expect(result.reason).to eq(:remote_proxy_unreachable)
      expect(result.message).to include("proxy")
    end
  end

  describe "no resolvable auth" do
    it "is rejected with managed_auth_missing" do
      result = described_class.call(
        backend: remote_backend,
        auth_source: auth_source(runner_key: "claude", auth_mode: :none)
      )

      expect(result.reason).to eq(:managed_auth_missing)
      expect(result.message).to include("managed claude credential")
    end
  end

  describe "secret safety" do
    it "never includes token-like content in rejection messages" do
      secrets = %w[sk-ant-oat01 abc123token refresh-token-value bearer]
      results = [
        described_class.call(backend: remote_backend,
          auth_source: auth_source(runner_key: "claude", auth_mode: :managed, credential_state: :expired)),
        described_class.call(backend: remote_backend,
          auth_source: auth_source(runner_key: "codex", auth_mode: :host_forwarded)),
        described_class.call(backend: remote_backend,
          auth_source: auth_source(runner_key: "claude", auth_mode: :none))
      ]

      results.each do |result|
        secrets.each do |secret|
          expect(result.message).not_to include(secret)
        end
      end
    end
  end

  describe ".eligible_for_non_subscription" do
    it "returns an eligible result for runners that do not need subscription auth" do
      result = described_class.eligible_for_non_subscription(backend: remote_backend)

      expect(result).to be_eligible
      expect(result.reason).to be_nil
    end
  end
end
