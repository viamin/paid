# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Check = Data.define(:producer, :fit, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)
      Plan = Data.define(:selected_checks, :exclusions)

      def self.call(...)
        new(...).call
      end

      def initialize(selected_checks:, exclusions:)
        @selected_checks = selected_checks
        @exclusions = exclusions
      end

      def call
        Plan.new(selected_checks: selected_checks.map { |check| build_check(check) }, exclusions: exclusions)
      end

      private

      attr_reader :exclusions, :selected_checks

      def build_check(check)
        payload = check.deep_symbolize_keys
        Check.new(**payload.slice(*Check.members)).tap { |result| validate!(result) }
      end

      def validate!(check)
        raise ArgumentError, "Each selected check requires a producer and fit rationale" if check.producer.blank? || check.fit.blank?
      end
    end
  end
end
