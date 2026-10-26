# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      REQUIRED_CHECK_FIELDS = %w[producer fit required_inputs assumptions resource_expectations residual_gaps].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(selected_checks:, omissions:)
        @selected_checks = selected_checks
        @omissions = omissions
      end

      def call
        normalized_checks = selected_checks.map { |check| normalize_check(check) }
        raise ArgumentError, "at least one selected check is required" if normalized_checks.empty?

        { "selected_checks" => normalized_checks, "omissions" => omissions.map { |omission| normalize_omission(omission) } }
      end

      private

      attr_reader :omissions, :selected_checks

      def normalize_check(check)
        value = check.stringify_keys
        missing = REQUIRED_CHECK_FIELDS.reject { |field| value.key?(field) }
        raise ArgumentError, "check is missing: #{missing.join(', ')}" if missing.any?
        raise ArgumentError, "unknown check producer" unless value.fetch("producer").in?(LayeredVerificationCheckResult::PRODUCERS)

        value.slice(*REQUIRED_CHECK_FIELDS)
      end

      def normalize_omission(omission)
        value = omission.stringify_keys
        raise ArgumentError, "omission requires producer and reason" if value.values_at("producer", "reason").any?(&:blank?)

        value.slice("producer", "reason")
      end
    end
  end
end
