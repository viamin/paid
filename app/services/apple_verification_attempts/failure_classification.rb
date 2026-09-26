# frozen_string_literal: true

module AppleVerificationAttempts
  # Taxonomy for classifying Apple verification attempt failures.
  # @spec APPLE-ATTEMPT-009
  # @spec APPLE-ATTEMPT-010
  module FailureClassification
    TAXONOMY = AppleVerificationAttempt::FAILURE_CLASSIFICATIONS
    INFRASTRUCTURE = %w[capacity_or_quota worker_infrastructure cancellation_or_timeout].freeze
    PROJECT = (TAXONOMY - INFRASTRUCTURE).freeze

    def self.valid?(classification)
      TAXONOMY.include?(classification)
    end

    def self.infrastructure?(classification)
      INFRASTRUCTURE.include?(classification)
    end

    def self.project?(classification)
      PROJECT.include?(classification)
    end
  end
end
