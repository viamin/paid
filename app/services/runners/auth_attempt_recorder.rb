# frozen_string_literal: true

module Runners
  # RDR-041 / #2960 — single seam for writing runner auth attempt telemetry.
  #
  # Containers::Provision (and any future caller) routes through this service
  # so the redaction contract is enforced in exactly one place. The recorder:
  #
  #   1. Resolves the canonical auth_source + materialization_mode from the
  #      auth_source struct passed in by the caller.
  #   2. Captures the resolved feature-flag state for managed_subscription_runner_auth.
  #   3. Captures backend capability (supports_host_paths?, remote?) from the
  #      Docker backend when one is provided.
  #   4. Persists a RunnerAuthAttempt row inside a savepoint (transaction
  #      requires_new: true) so a validation/insert failure inside the
  #      recorder cannot poison the caller's outer transaction. Note this
  #      is partial-rollback isolation, not durability: if the caller's
  #      outer transaction rolls back, this telemetry row is lost too.
  #
  # Anything that smells like a secret — token, refresh token, auth code, native
  # credential JSON, etc. — is rejected before persistence (see
  # SecretSafeMetadata::FORBIDDEN_METADATA_KEYS and SECRET_VALUE_PATTERNS).
  class AuthAttemptRecorder
    FEATURE_FLAG_NAME = :managed_subscription_runner_auth

    Result = Struct.new(:recorded, :error, keyword_init: true) do
      def recorded? = recorded == true
    end

    def self.call(**attrs)
      new(**attrs).call
    end

    def initialize(agent_run:, project:, runner_key:, attempt_stage:, result:,
      auth_source: nil, materialization_mode: nil, container_host: nil,
      backend: nil, runner_credential: nil, refresh_state: nil,
      lease_state: nil, failure_reason: nil, duration_ms: nil,
      retry_count: 0, metadata: {}, feature_flag_state: nil, attempted_at: nil)
      @agent_run = agent_run
      @project = project
      @runner_key = runner_key
      @attempt_stage = attempt_stage
      @result = result
      @auth_source = auth_source
      @materialization_mode = materialization_mode
      @container_host = container_host
      @backend = backend
      @runner_credential = runner_credential
      @refresh_state = refresh_state
      @lease_state = lease_state
      @failure_reason = failure_reason
      @duration_ms = duration_ms
      @retry_count = retry_count
      @metadata = metadata
      @feature_flag_state = feature_flag_state
      @attempted_at = attempted_at
    end

    def call
      attrs = build_attributes
      record_in_isolated_transaction(attrs)
    end

    private

    attr_reader :agent_run, :project, :runner_key, :attempt_stage, :result,
      :auth_source, :materialization_mode, :container_host, :backend,
      :runner_credential, :refresh_state, :lease_state, :failure_reason,
      :duration_ms, :retry_count, :metadata, :feature_flag_state, :attempted_at

    def build_attributes
      {
        account: resolved_account,
        project: project,
        agent_run: agent_run,
        runner_credential: runner_credential,
        runner_key: runner_key.to_s,
        attempt_stage: attempt_stage.to_s,
        auth_source: resolved_auth_source,
        materialization_mode: materialization_mode&.to_s,
        container_host: resolved_container_host,
        backend_supports_host_paths: backend_capability_supports_host_paths?,
        backend_remote: backend_capability_remote?,
        feature_flag_state: resolved_feature_flag_state,
        refresh_state: refresh_state&.to_s,
        lease_state: lease_state&.to_s,
        result: result.to_s,
        failure_reason: failure_reason,
        duration_ms: duration_ms,
        retry_count: retry_count,
        attempted_at: attempted_at || Time.current,
        metadata: metadata.to_h
      }
    end

    def resolved_account
      return project.account if project&.account.present?

      # Project may be derived from agent_run by the model's
      # assign_project_from_agent_run callback; mirror that here so the
      # NOT NULL account_id column is satisfied when only agent_run is given.
      agent_run&.project&.account
    end

    def resolved_auth_source
      if auth_source.is_a?(Runners::SubscriptionAuthEligibility::AuthSource)
        auth_source.auth_mode.to_s
      else
        auth_source.to_s.presence || RunnerAuthAttempt::AUTH_SOURCE_NONE
      end
    end

    def resolved_container_host
      return container_host.to_s if container_host.present?
      return backend.identifier.to_s if backend.respond_to?(:identifier)

      nil
    end

    def backend_capability_supports_host_paths?
      return nil unless backend

      backend.respond_to?(:supports_host_paths?) ? backend.supports_host_paths? : nil
    end

    def backend_capability_remote?
      return nil unless backend

      backend.respond_to?(:remote?) ? backend.remote? : nil
    end

    def resolved_feature_flag_state
      return feature_flag_state.to_s if feature_flag_state.present?

      FeatureFlags.definition(FEATURE_FLAG_NAME).name # raises if missing — translate to unregistered
      FeatureFlags.enabled?(FEATURE_FLAG_NAME, project: project) ? RunnerAuthAttempt::FLAG_ENABLED : RunnerAuthAttempt::FLAG_DISABLED
    rescue FeatureFlags::UnknownFlagError
      RunnerAuthAttempt::FLAG_UNREGISTERED
    end

    def record_in_isolated_transaction(attrs)
      # Savepoint-isolated from the caller: a failure inside this block rolls
      # back only the savepoint, not the caller's outer transaction. May still
      # be lost on outer rollback (requires_new opens a savepoint, not a
      # separate physical transaction).
      row = RunnerAuthAttempt.transaction(requires_new: true) do
        RunnerAuthAttempt.create!(attrs)
      end
      log_attempt_recorded(row)
      Result.new(recorded: true, error: nil)
    rescue StandardError => e
      # The recorder is the single seam for runner auth telemetry, so the same
      # redaction contract that applies to the row applies to its log output.
      # A RunnerAuthAttempt validation error message echoes the caller's
      # metadata key/value (e.g. "contains forbidden key #{key.inspect}"), so
      # logging e.message unsanitized would let caller input reach Rails.logger.
      # Keep only the class name here; per-attempt context is in the row itself.
      Rails.logger.warn(
        message: "runners.auth_attempt.record_failed",
        runner_key: runner_key,
        attempt_stage: attempt_stage,
        result: result,
        error_class: e.class.name
      )
      Result.new(recorded: false, error: e)
    end

    def log_attempt_recorded(row)
      Rails.logger.info(
        message: "runners.auth_attempt.recorded",
        runner_auth_attempt_id: row.id,
        account_id: row.account_id,
        project_id: row.project_id,
        agent_run_id: row.agent_run_id,
        runner_key: row.runner_key,
        attempt_stage: row.attempt_stage,
        auth_source: row.auth_source,
        container_host: row.container_host,
        result: row.result
      )
    end
  end
end
