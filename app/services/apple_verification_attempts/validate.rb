# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-005
  # Pre-admission validation for an Apple verification attempt. Runs before
  # capacity is reserved so configuration, source, capability, policy, and
  # quota failures do not consume the worker slot or strand a half-cloned
  # VM. Each validation failure maps to a deterministic
  # {AppleVerificationAttempts::FailureClassification} so the
  # project_configuration vs. unsupported_capability distinction is preserved
  # in the terminal state and audit trail.
  class Validate
    Decision = Data.define(:allowed, :reason, :classification, :attempt) do
      def allowed?
        allowed
      end
    end

    REASONS = %w[
      allowed
      workflow_not_approved
      workflow_profile_revoked
      worker_quarantined
      workflow_gate_mismatch
      source_digest_missing
      capability_unsupported
      policy_denied
      quota_exceeded
      attempt_state_invalid
    ].freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt:,
      profile_constraints_resolver: nil,
      policy_resolver: nil,
      quota_resolver: nil
    )
      @attempt = attempt
      @profile_constraints_resolver = profile_constraints_resolver || method(:default_profile_constraints)
      @policy_resolver = policy_resolver || method(:default_policy)
      @quota_resolver = quota_resolver || method(:default_quota)
    end

    def call
      attempt = @attempt
      workflow = attempt.apple_verification_workflow_revision

      unless workflow_eligible?(workflow)
        return deny("workflow_not_approved", "project_configuration")
      end
      if workflow.apple_worker_profile&.revoked?
        return deny("workflow_profile_revoked", "unsupported_capability")
      end
      if workflow.apple_worker_profile&.quarantined?
        return deny("worker_quarantined", "worker_infrastructure")
      end
      unless workflow.lifecycle_gate == attempt.lifecycle_gate
        return deny("workflow_gate_mismatch", "project_configuration")
      end
      if attempt.source_digest.blank? || attempt.source_digest == "sha256:" + ("0" * 64)
        return deny("source_digest_missing", "project_configuration")
      end
      unless @profile_constraints_resolver.call(workflow.apple_worker_profile, attempt)
        return deny("capability_unsupported", "unsupported_capability")
      end
      unless @policy_resolver.call(attempt)
        return deny("policy_denied", "network_policy")
      end
      unless @quota_resolver.call(attempt)
        return deny("quota_exceeded", "capacity_or_quota")
      end
      unless attempt.queued? || attempt.status.nil?
        return deny("attempt_state_invalid", "project_configuration")
      end

      allow
    end

    private

    attr_reader :attempt

    def allow
      Decision.new(allowed: true, reason: "allowed", classification: nil, attempt:)
    end

    def deny(reason, classification)
      Decision.new(allowed: false, reason:, classification:, attempt:)
    end

    def workflow_eligible?(workflow)
      workflow&.approved? || (workflow&.draft? && workflow.lifecycle_gate == "agent_iteration")
    end

    def default_profile_constraints(profile, attempt)
      return false unless profile

      capabilities = profile.capabilities.is_a?(Hash) ? profile["capabilities"] : profile.capabilities
      return false if capabilities.blank?

      true
    end

    def default_policy(_attempt)
      FeatureFlags.enabled?(:apple_verification_workers, project: attempt.project)
    end

    def default_quota(attempt)
      queue = Queue.new
      account_attempts = Queue.new(account_scope: attempt.account).call
      return false if account_attempts.size >= queue.queue_depth_limit
      return false if attempts_per_agent_run_exceeded?(attempt)

      true
    end

    def attempts_per_agent_run_exceeded?(attempt)
      return false unless attempt.agent_run_id

      count = AppleVerificationAttempt.where(agent_run_id: attempt.agent_run_id).count
      count >= Queue::DEFAULT_MAX_ATTEMPTS_PER_RUN
    end
  end
end
