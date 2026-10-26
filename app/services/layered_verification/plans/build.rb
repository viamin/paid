# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Plan = Data.define(:selected_checks, :omissions, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...)
        new(...).call
      end

      def initialize(selected_checks:, omissions: [], assumptions: [], resource_expectations: {}, residual_gaps: [])
        @selected_checks = Array(selected_checks)
        @omissions = Array(omissions)
        @assumptions = Array(assumptions)
        @resource_expectations = resource_expectations || {}
        @residual_gaps = Array(residual_gaps)
      end

      def call
        validate_checks!
        Plan.new(selected_checks:, omissions:, assumptions:, resource_expectations:, residual_gaps:)
      end

      private

      attr_reader :selected_checks, :omissions, :assumptions, :resource_expectations, :residual_gaps

      def validate_checks!
        selected_checks.each do |check|
          raise ArgumentError, "every selected check needs fit and limitations" unless check.is_a?(Hash) && check[:fit].present? && check[:limitations].present?
        end
      end
    end
  end
end
