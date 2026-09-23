# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-009
  # Closed taxonomy of failure classifications for Apple verification
  # attempts. Capacity exhaustion, admission refusal, infrastructure
  # timeout, and other host-side failures MUST classify into an
  # infrastructure-only bucket — they are never code failures, and a
  # deterministic classifier keeps the taxonomy honest when new code paths
  # reach for a custom value.
  class FailureClassification
    TAXONOMY = %w[
      project_configuration
      compile_or_link
      test_assertion
      launch_or_ui_flow
      required_capture
      network_policy
      unsupported_capability
      capacity_or_quota
      worker_infrastructure
      cancellation_or_timeout
    ].freeze

    INFRASTRUCTURE_CLASSIFICATIONS = %w[
      capacity_or_quota
      worker_infrastructure
      cancellation_or_timeout
    ].freeze

    PROJECT_CLASSIFICATIONS = %w[
      project_configuration
      compile_or_link
      test_assertion
      launch_or_ui_flow
      required_capture
      network_policy
      unsupported_capability
    ].freeze

    InvalidClassificationError = Class.new(ArgumentError)

    class << self
      def classify(value)
        return nil if value.blank?

        normalized = value.to_s
        return normalized if TAXONOMY.include?(normalized)

        raise InvalidClassificationError, "unknown Apple verification failure classification: #{value.inspect}"
      end

      def infrastructure?(classification)
        INFRASTRUCTURE_CLASSIFICATIONS.include?(classification.to_s)
      end

      def project?(classification)
        PROJECT_CLASSIFICATIONS.include?(classification.to_s)
      end
    end

    def initialize(value)
      @value = self.class.classify(value)
    end

    attr_reader :value

    def infrastructure?
      self.class.infrastructure?(@value)
    end

    def project?
      self.class.project?(@value)
    end
  end
end
