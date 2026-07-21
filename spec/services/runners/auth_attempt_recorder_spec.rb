# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::AuthAttemptRecorder do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:backend) do
    instance_double(Containers::Backends::Base, identifier: "local", remote?: false, supports_host_paths?: true)
  end

  describe ".call" do
    it "records a managed materialization attempt" do
      result = described_class.call(
        agent_run: agent_run,
        project: project,
        backend: backend,
        runner_key: "claude",
        attempt_stage: RunnerAuthAttempt::STAGE_MATERIALIZATION,
        auth_source: :managed,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_ENV,
        result: RunnerAuthAttempt::RESULT_MATERIALIZED
      )

      expect(result.recorded?).to be(true)
    end

    it "stores the resolved fields for a managed materialization attempt" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: :managed, materialization_mode: "env",
        result: "materialized"
      )

      attempt = RunnerAuthAttempt.last
      expect(attempt.runner_key).to eq("claude")
      expect(attempt.attempt_stage).to eq("materialization")
      expect(attempt.auth_source).to eq("managed")
      expect(attempt.materialization_mode).to eq("env")
      expect(attempt.result).to eq("materialized")
      expect(attempt.account).to eq(account)
      expect(attempt.project).to eq(project)
      expect(attempt.container_host).to eq("local")
      expect(attempt.backend_supports_host_paths).to be(true)
      expect(attempt.backend_remote).to be(false)
    end

    it "captures AuthSource structs without leaking the struct" do
      auth_source = Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: "claude", auth_mode: :managed, credential_state: :active
      )
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: auth_source, materialization_mode: "env",
        result: "materialized"
      )

      attempt = RunnerAuthAttempt.last
      expect(attempt.auth_source).to eq("managed")
    end

    it "records eligibility rejections with a named failure_reason" do
      remote_backend = instance_double(Containers::Backends::RemoteDocker,
        identifier: "elguapo", remote?: true, supports_host_paths?: false)

      result = described_class.call(
        agent_run: agent_run, project: project, backend: remote_backend,
        runner_key: "codex", attempt_stage: RunnerAuthAttempt::STAGE_ELIGIBILITY,
        auth_source: :host_forwarded,
        materialization_mode: Runners::SubscriptionAuthMaterializers::MATERIALIZE_HOST_MOUNT,
        result: RunnerAuthAttempt::RESULT_FAILED,
        failure_reason: :requires_host_bind_mount
      )

      expect(result.recorded?).to be(true)
      attempt = RunnerAuthAttempt.last
      expect(attempt.container_host).to eq("elguapo")
      expect(attempt.backend_supports_host_paths).to be(false)
      expect(attempt.backend_remote).to be(true)
      expect(attempt.failure_reason).to eq("requires_host_bind_mount")
    end

    it "captures the resolved feature flag state" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: :managed, materialization_mode: "env",
        result: "materialized"
      )

      expect(RunnerAuthAttempt.last.feature_flag_state).to eq("disabled")
    end

    it "captures refresh state and duration_ms" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "refresh",
        auth_source: :host_forwarded, materialization_mode: "host_mount",
        refresh_state: "refreshed", result: "refreshed",
        duration_ms: 250
      )

      attempt = RunnerAuthAttempt.last
      expect(attempt.refresh_state).to eq("refreshed")
      expect(attempt.duration_ms).to eq(250)
    end

    it "captures lease state and result mapping" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "codex", attempt_stage: "lease",
        auth_source: :host_forwarded, materialization_mode: "host_mount",
        lease_state: "timeout", result: "lease_timeout",
        failure_reason: "lock_timeout"
      )

      attempt = RunnerAuthAttempt.last
      expect(attempt.lease_state).to eq("timeout")
      expect(attempt.result).to eq("lease_timeout")
      expect(attempt.failure_reason).to eq("lock_timeout")
    end

    it "captures harvest outcome" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "codex", attempt_stage: "harvest",
        auth_source: :host_forwarded, materialization_mode: "host_mount",
        result: "harvested", duration_ms: 180
      )

      attempt = RunnerAuthAttempt.last
      expect(attempt.attempt_stage).to eq("harvest")
      expect(attempt.result).to eq("harvested")
      expect(attempt.duration_ms).to eq(180)
    end

    it "captures retry_count" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "codex", attempt_stage: "harvest",
        auth_source: :host_forwarded, materialization_mode: "host_mount",
        result: "harvest_failed", retry_count: 3
      )

      expect(RunnerAuthAttempt.last.retry_count).to eq(3)
    end

    it "resolves the container_host from backend.identifier when not given" do
      described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: :managed, materialization_mode: "env",
        result: "materialized"
      )

      expect(RunnerAuthAttempt.last.container_host).to eq("local")
    end

    it "rejects attempts with secret-shaped metadata and returns a failed result" do
      result = described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: :managed, materialization_mode: "env",
        result: "materialized",
        metadata: { token: "sk-ant-oat01-abcdef0123456789" }
      )

      expect(result.recorded?).to be(false)
      expect(result.error).to be_a(ActiveRecord::RecordInvalid)
    end

    it "does not raise on safe metadata values" do
      result = described_class.call(
        agent_run: agent_run, project: project, backend: backend,
        runner_key: "claude", attempt_stage: "materialization",
        auth_source: :managed, materialization_mode: "env",
        result: "materialized",
        metadata: { source: "managed_env_token", rotation_risk: "server_refresh_only" }
      )

      expect(result.recorded?).to be(true)
    end

    it "rolls back only the savepoint when validation fails inside an outer transaction" do
      created_project = nil
      recorder_result = nil

      ActiveRecord::Base.transaction do
        recorder_result = described_class.call(
          agent_run: agent_run, project: project, backend: backend,
          runner_key: "claude", attempt_stage: "materialization",
          auth_source: :managed, materialization_mode: "env",
          result: "materialized",
          metadata: { token: "x" }
        )
        created_project = create(:project, account: account)
      end

      expect(recorder_result.recorded?).to be(false)
      expect(recorder_result.error).to be_a(ActiveRecord::RecordInvalid)
      expect(created_project).to be_persisted
      expect(Project.exists?(created_project.id)).to be(true)
    end
  end
end
