# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Containers::Provision do # @spec SUBSCRIPTION-RUNNER-AUTH-002
  # Codex managed subscription auth (RDR-041 / #2962).
  let(:local_backend) do
    instance_double(
      Containers::Backends::Base,
      identifier: "local",
      remote?: false,
      supports_host_paths?: true
    )
  end

  let(:remote_backend) do
    instance_double(
      Containers::Backends::RemoteDocker,
      identifier: "elguapo",
      remote?: true,
      supports_host_paths?: false
    )
  end

  let(:account) { create(:account) }
  let(:project) do
    create(:project, account: account, created_by: create(:user, account: account))
  end
  let(:agent_run) { create(:agent_run, project: project) }
  let(:container) { instance_double(Docker::Container) }

  let(:valid_codex_auth) { file_fixture("codex_auth_valid.json").read }

  def create_codex_credential(token:, expires_at: nil)
    create(
      :runner_credential,
      account: project.account,
      created_by: project.created_by,
      runner_key: "codex",
      auth_kind: "oauth_token",
      token: token,
      expires_at: expires_at
    )
  end

  def build_service(backend: local_backend, credential: nil)
    svc = described_class.new(agent_run: agent_run, project: project, backend: backend)
    allow(svc).to receive_messages(
      codex_local_config_path: nil,
      codex_subscription_auth_host_mount_path: nil,
      codex_subscription_auth_mount: nil,
      log_system: nil
    )
    allow(svc).to receive(:codex_managed_runner_credential).and_return(credential) if credential
    svc
  end

  describe "managed materialization without a host bind mount (AC1)" do
    it "writes auth.json into the container from the managed RunnerCredential" do
      credential = create_codex_credential(token: valid_codex_auth)
      svc = build_service(credential: credential)

      written = {}
      allow(svc).to receive(:write_container_file) { |path, content| written[path] = content }
      allow(svc).to receive(:refresh_codex_managed_credential!).and_return(nil)
      allow(svc).to receive(:seed_codex_managed_config!)
      allow(svc).to receive(:seed_codex_notify_hook!)

      svc.send(:seed_codex_credentials!)

      expect(written.keys).to include("/home/agent/.codex/auth.json")
      materialized = JSON.parse(written.fetch("/home/agent/.codex/auth.json"))
      expect(materialized["tokens"]["refresh_token"]).to eq("v1.managed-codex-refresh-token")

      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "materialization").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.materialization_mode).to eq("native_file")
      expect(attempt.runner_credential).to eq(credential)
      expect(attempt.result).to eq("materialized")
      expect(attempt.metadata).not_to include("managed-codex-refresh-token")
    end

    it "marks the credential last_used_at when materialized" do
      credential = create_codex_credential(token: valid_codex_auth, expires_at: nil)
      svc = build_service(credential: credential)

      allow(svc).to receive(:write_container_file)
      allow(svc).to receive(:refresh_codex_managed_credential!).and_return(nil)
      allow(svc).to receive(:seed_codex_managed_config!)
      allow(svc).to receive(:seed_codex_notify_hook!)

      expect { svc.send(:seed_codex_credentials!) }.to change { credential.reload.last_used_at }.from(nil)
    end

    it "falls back to the host-mount path when no managed credential exists" do
      svc = build_service
      allow(svc).to receive_messages(
        materialize_managed_codex_credentials!: false,
        codex_subscription_auth?: true,
        codex_subscription_auth_mount: nil,
        record_auth_attempt!: nil,
        seed_codex_config!: nil,
        seed_codex_notify_hook!: nil
      )

      svc.send(:seed_codex_credentials!)

      expect(svc).to have_received(:seed_codex_config!)
    end
  end

  describe "harvesting a rotated auth.json back into the credential (AC2)" do
    let(:credential) { create_codex_credential(token: valid_codex_auth) }

    def rotated_codex_auth
      payload = JSON.parse(valid_codex_auth)
      payload["tokens"]["access_token"] = "eyJrotated-access-token"
      payload["tokens"]["refresh_token"] = "v1.rotated-refresh-token"
      JSON.generate(payload)
    end

    it "updates the canonical RunnerCredential with rotated state" do
      svc = build_service(credential: credential)
      encoded = Base64.strict_encode64(rotated_codex_auth)
      allow(local_backend).to receive(:exec_in_container).and_return([ [ encoded ], [], 0 ])

      svc.send(:harvest_codex_managed_credential!)

      credential.reload
      parsed = JSON.parse(credential.token)
      expect(parsed["tokens"]["access_token"]).to eq("eyJrotated-access-token")
      expect(parsed["tokens"]["refresh_token"]).to eq("v1.rotated-refresh-token")

      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "harvest").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.result).to eq("harvested")
      expect(attempt.metadata).not_to include("rotated-refresh-token")
    end

    it "records a skipped harvest when no rotated credential is returned" do
      svc = build_service(credential: credential)
      allow(local_backend).to receive(:exec_in_container).and_return([ [], [], 0 ])

      result = svc.send(:harvest_codex_managed_credential!)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("no_rotated_credential")
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "harvest").last
      expect(attempt.result).to eq("skipped")
    end

    it "records a harvest failure when the container exec fails" do
      svc = build_service(credential: credential)
      allow(local_backend).to receive(:exec_in_container).and_return([ [], [ "boom" ], 1 ])

      result = svc.send(:harvest_codex_managed_credential!)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("harvest_failed")
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "harvest").last
      expect(attempt.result).to eq("harvest_failed")
    end

    it "does not corrupt the credential when the rotated payload is malformed" do
      original_token = credential.token
      svc = build_service(credential: credential)
      encoded = Base64.strict_encode64('{"tokens":{}}')
      allow(local_backend).to receive(:exec_in_container).and_return([ [ encoded ], [], 0 ])

      svc.send(:harvest_codex_managed_credential!)

      expect(credential.reload.token).to eq(original_token)
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "harvest").last
      expect(attempt.result).to eq("harvest_failed")
      expect(attempt.failure_reason).to eq("malformed_rotated_credential")
    end

    it "records a harvest failure when the rotated payload has no access token" do
      original_token = credential.token
      svc = build_service(credential: credential)
      refresh_only = JSON.parse(valid_codex_auth)
      refresh_only["tokens"].delete("access_token")
      encoded = Base64.strict_encode64(JSON.generate(refresh_only))
      allow(local_backend).to receive(:exec_in_container).and_return([ [ encoded ], [], 0 ])

      result = svc.send(:harvest_codex_managed_credential!)

      expect(result.performed?).to be(false)
      expect(result.reason).to eq("rotated_credential_missing_access_token")
      expect(credential.reload.token).to eq(original_token)
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "harvest").last
      expect(attempt.result).to eq("harvest_failed")
      expect(attempt.failure_reason).to eq("rotated_credential_missing_access_token")
    end
  end

  describe "per-credential lease serialization (AC3)" do
    let(:credential) { create_codex_credential(token: valid_codex_auth) }

    def lease_service(stub_lease_recorder: true)
      svc = build_service(credential: credential)
      allow(svc).to receive_messages(
        codex_managed_runner_credential: credential,
        subscription_auth_lock_timeout: 5
      )
      allow(svc).to receive(:record_codex_lease_attempt!) if stub_lease_recorder
      allow(svc).to receive(:harvest_codex_managed_credential!)
      svc
    end

    it "keys the lease lockfile on the credential id" do
      other = create_codex_credential(token: valid_codex_auth)
      svc_a = build_service(credential: credential)
      svc_b = build_service(credential: other)

      expect(svc_a.send(:codex_managed_auth_lockfile_path)).not_to eq(svc_b.send(:codex_managed_auth_lockfile_path))
    end

    it "serializes concurrent execs sharing the same credential" do
      svc = lease_service
      reset_lockfile(svc)

      intervals = []
      mutex = Mutex.new
      run_critical_section = -> {
        start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.3
        end_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        mutex.synchronize { intervals << [ start_at, end_at ] }
      }
      threads = Array.new(2) do
        Thread.new { svc.send(:with_codex_managed_auth_lock) { run_critical_section.call } }
      end
      threads.each(&:join)

      sorted = intervals.sort_by(&:first)
      expect(sorted.size).to eq(2)
      # The second interval must start after the first ends (no overlap).
      expect(sorted[1][0]).to be >= sorted[0][1]
    end

    it "records a managed lease telemetry row when the lock is acquired" do
      svc = lease_service(stub_lease_recorder: false)
      reset_lockfile(svc)

      svc.send(:with_codex_managed_auth_lock) { :ran }

      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "lease").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.materialization_mode).to eq("native_file")
      expect(attempt.lease_state).to eq("acquired")
      expect(attempt.runner_credential).to eq(credential)
    end

    def reset_lockfile(svc)
      lockfile = svc.send(:codex_managed_auth_lockfile_path)
      File.delete(lockfile) if File.exist?(lockfile)
    end
  end

  describe "refresh-before-run (server-side, gated on agent-harness)" do
    let(:credential) { create_codex_credential(token: valid_codex_auth, expires_at: 1.minute.from_now) }

    it "records a refresh telemetry row and skips when the upstream exchange is unsupported" do
      svc = build_service(credential: credential)

      outcome = svc.send(:refresh_codex_managed_credential_if_needed!, provision: true)

      expect(outcome).to be(false)
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "refresh").last
      expect(attempt).not_to be_nil
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.result).to eq("refresh_failed").or(eq("skipped"))
    end

    it "persists a refreshed token when the exchange returns new state" do
      svc = build_service(credential: credential)
      allow(svc).to receive_messages(
        codex_managed_runner_credential: credential,
        codex_refresh_exchange_supported?: true
      )
      refreshed = JSON.parse(valid_codex_auth)
      refreshed["tokens"]["access_token"] = "eyJserver-refreshed-access"
      allow(AgentHarness::Authentication).to receive(:exchange_refresh_token).and_return(refreshed)

      svc.send(:refresh_codex_managed_credential_if_needed!, provision: true)

      parsed = JSON.parse(credential.reload.token)
      expect(parsed["tokens"]["access_token"]).to eq("eyJserver-refreshed-access")
    end

    it "does not brick the credential when the refresh response is not a Codex auth" do
      svc = build_service(credential: credential)
      allow(svc).to receive_messages(
        codex_managed_runner_credential: credential,
        codex_refresh_exchange_supported?: true
      )
      credential.update!(revoked_at: 1.hour.ago)
      original_token = credential.token
      allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)
        .and_return({ "error" => "invalid_grant", "error_description" => "bad refresh token" })

      svc.send(:refresh_codex_managed_credential_if_needed!, provision: true)

      expect(credential.reload.token).to eq(original_token)
      # The old code cleared revoked_at on any response; the fix leaves it intact.
      expect(credential.reload.revoked_at).to be_within(1.second).of(1.hour.ago)
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "refresh").last
      expect(attempt.result).to eq("refresh_failed")
    end

    it "rejects a refresh response that carries no access token" do
      svc = build_service(credential: credential)
      allow(svc).to receive_messages(
        codex_managed_runner_credential: credential,
        codex_refresh_exchange_supported?: true
      )
      original_token = credential.token
      refresh_only = JSON.parse(valid_codex_auth)
      refresh_only["tokens"].delete("access_token")
      allow(AgentHarness::Authentication).to receive(:exchange_refresh_token).and_return(refresh_only)

      svc.send(:refresh_codex_managed_credential_if_needed!, provision: true)

      expect(credential.reload.token).to eq(original_token)
      attempt = RunnerAuthAttempt.where(runner_key: "codex", attempt_stage: "refresh").last
      expect(attempt.result).to eq("refresh_failed")
    end
  end

  describe "remote Docker eligibility stays disabled (AC4)" do
    it "keeps the Codex materializer remote_safe? false" do
      expect(Runners::SubscriptionAuthMaterializers.remote_safe?("codex")).to be(false)
    end

    it "rejects a managed Codex credential on a remote backend with provider_materializer_missing" do
      result = Runners::SubscriptionAuthEligibility.call(
        backend: remote_backend,
        auth_source: Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: "codex", auth_mode: :managed, credential_state: :active
        )
      )

      expect(result).to be_ineligible
      expect(result.reason).to eq(:provider_materializer_missing)
    end
  end
end
