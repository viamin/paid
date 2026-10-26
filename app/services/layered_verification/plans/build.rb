# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Plan = Data.define(:obligation_ids, :selected_checks, :available_artifacts, :exclusions, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(obligations:, available_artifacts:, selected_checks:, exclusions: {}, assumptions: [], resource_expectations: {})
        @obligations = obligations
        @available_artifacts = available_artifacts
        @selected_checks = selected_checks
        @exclusions = exclusions
        @assumptions = assumptions
        @resource_expectations = resource_expectations
      end

      def call
        Plan.new(obligation_ids, selected_checks, available_artifacts, exclusions, assumptions, resource_expectations, residual_gaps)
      end

      private

      attr_reader :obligations, :available_artifacts, :selected_checks, :exclusions, :assumptions, :resource_expectations

      def obligation_ids = obligations.map(&:id)

      def residual_gaps
        LayeredVerificationCheckResult::PRODUCERS.reject { |check| check.in?(selected_checks) }
          .map { |check| "#{check} was not selected" }
      end
    end
  end
end
