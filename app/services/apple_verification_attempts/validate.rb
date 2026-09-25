# frozen_string_literal: true

module AppleVerificationAttempts
  # Validates preconditions on a queued Apple verification attempt before it is
  # allocated a guest. When a precondition fails, the attempt is marked failed
  # with the matching failure classification; otherwise it is left untouched.
  # @spec APPLE-ATTEMPT-005
  class Validate
    Result = Data.define(:valid, :classification, :reason)

    SOURCE_DIGEST_PATTERN = /\Asha256:[a-f0-9]{64}\z/
    COMMIT_SHA_PATTERN = /\A[0-9a-f]{40}\z/

    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      classification, reason = first_failure
      return Result.new(valid: true, classification: nil, reason: nil) unless classification

      @attempt.update_columns(
        status: "failed",
        finished_at: Time.current,
        failure_classification: classification
      )
      Result.new(valid: false, classification:, reason:)
    end

    private

    def first_failure
      project_configuration_failure || unsupported_capability_failure
    end

    def project_configuration_failure
      return [ "project_configuration", "project mode is off" ] if project_mode_off?
      return [ "project_configuration", "feature flag disabled" ] unless feature_flag_enabled?
      return [ "project_configuration", "workflow revision not eligible" ] unless workflow_revision_eligible?
      return [ "project_configuration", "source digest is blank" ] if source_digest_blank?
      return [ "project_configuration", "source digest is invalid" ] unless source_digest_valid?
      return [ "project_configuration", "commit sha is invalid" ] if commit_sha_invalid?

      quota_failure
    end

    def unsupported_capability_failure
      return nil unless @attempt.apple_worker_profile&.revoked?

      [ "unsupported_capability", "worker profile revoked" ]
    end

    def quota_failure
      return nil unless @attempt.agent_run_id

      prior = run_attempts
      return [ "project_configuration", "active attempt already exists" ] if prior.where.not(status: AppleVerificationAttempt::TERMINAL_STATES).exists?
      return [ "project_configuration", "attempts per run quota exceeded" ] if prior.count >= Config.max_attempts_per_run

      nil
    end

    def project_mode_off?
      @attempt.project.apple_verification_mode == "off"
    end

    def feature_flag_enabled?
      FeatureFlags.enabled?(:apple_verification_workers, project: @attempt.project)
    end

    def workflow_revision_eligible?
      revision = @attempt.apple_verification_workflow_revision
      revision.approved? || (revision.draft? && revision.lifecycle_gate == "agent_iteration")
    end

    def source_digest_blank?
      @attempt.source_digest.blank?
    end

    def source_digest_valid?
      SOURCE_DIGEST_PATTERN.match?(@attempt.source_digest)
    end

    def commit_sha_invalid?
      @attempt.commit_sha.present? && !COMMIT_SHA_PATTERN.match?(@attempt.commit_sha)
    end

    def run_attempts
      AppleVerificationAttempt.where(agent_run_id: @attempt.agent_run_id).where.not(id: @attempt.id)
    end
  end
end
