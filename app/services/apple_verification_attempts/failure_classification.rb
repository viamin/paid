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

      # Lenient classification for values read from an untrusted boundary:
      # the attempt's persisted `failure_classification` column and the
      # guest-result shape both accept any free-form string. Unknown
      # non-blank values resolve to nil rather than raising — an unknown
      # classification is not a deterministic project failure, so the
      # attempt stays retryable. Strict `classify` remains for internal
      # code paths, where an off-taxonomy value is a bug worth surfacing.
      def coerce(value)
        normalized = value.to_s
        TAXONOMY.include?(normalized) ? new(normalized) : new(nil)
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
