# frozen_string_literal: true

module AppleVerificationAttempts
  # Validates an attempt's immutable execution binding before capacity is claimed.
  # @spec APPLE-ATTEMPT-005
  class Validate
    Result = Data.define(:valid, :failure_classification, :reason) do
      def valid?
        valid
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      return failure("project_configuration", "Apple verification is disabled for this project") if attempt.project.apple_verification_mode == "off"
      return failure("project_configuration", "workflow revision is not eligible") unless attempt.apple_verification_workflow_revision.approved? || advisory_draft?
      return failure("unsupported_capability", "worker profile is not active") unless attempt.apple_worker_profile.active?

      Result.new(valid: true, failure_classification: nil, reason: nil)
    end

    private

    attr_reader :attempt

    def advisory_draft?
      attempt.apple_verification_workflow_revision.draft? && attempt.lifecycle_gate == "agent_iteration"
    end

    def failure(classification, reason)
      Result.new(valid: false, failure_classification: classification, reason:)
    end
  end
end
