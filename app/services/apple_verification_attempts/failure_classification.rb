# frozen_string_literal: true

module AppleVerificationAttempts
  # Closed result taxonomy that keeps infrastructure outcomes out of code failures.
  # @spec APPLE-ATTEMPT-009
  class FailureClassification
    ALL = %w[
      project_configuration compile_or_link test_assertion launch_or_ui_flow
      required_capture network_policy unsupported_capability capacity_or_quota
      worker_infrastructure cancellation_or_timeout
    ].freeze
    INFRASTRUCTURE = %w[capacity_or_quota worker_infrastructure cancellation_or_timeout].freeze
    PROJECT_FAILURES = ALL - INFRASTRUCTURE

    def self.infrastructure?(classification)
      INFRASTRUCTURE.include?(classification)
    end

    def self.valid?(classification)
      ALL.include?(classification)
    end
  end
end
