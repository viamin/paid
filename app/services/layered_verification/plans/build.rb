# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Plan = Data.define(:checks, :exclusions, :residual_gaps, :host_checks)
      HOST_CHECKS = [ "CI", "security", "branch protection", "code review", "approved-intent conformance" ].freeze
      REQUIRED_CHECK_FIELDS = %w[producer fit required_inputs assumptions resource_expectations limitations].freeze

      def self.call(...) = new(...).call

      def initialize(checks:, exclusions:, residual_gaps:)
        @checks = Array(checks)
        @exclusions = Array(exclusions)
        @residual_gaps = Array(residual_gaps)
      end

      def call
        validate!
        Plan.new(checks:, exclusions:, residual_gaps:, host_checks: HOST_CHECKS)
      end

      private

      attr_reader :checks, :exclusions, :residual_gaps

      def validate!
        raise ArgumentError, "at least one selected check is required" if checks.empty?
        checks.each { |check| validate_check!(check) }
        exclusions.each { |exclusion| validate_exclusion!(exclusion) }
      end

      def validate_check!(check)
        data = check.stringify_keys
        missing = REQUIRED_CHECK_FIELDS.reject { |field| data[field].present? }
        raise ArgumentError, "selected check is missing: #{missing.join(', ')}" if missing.any?
        raise ArgumentError, "unknown producer: #{data['producer']}" unless LayeredVerificationCheckResult::PRODUCERS.include?(data["producer"])
      end

      def validate_exclusion!(exclusion)
        data = exclusion.stringify_keys
        raise ArgumentError, "exclusion requires producer and reason" unless data["producer"].present? && data["reason"].present?
      end
    end
  end
end
