# frozen_string_literal: true

module LayeredVerification
  module Plans
    # A persisted-plan-shaped value object. Selection is supplied by the
    # bounded audit coordinator; this class makes every omission explicit and
    # deliberately permits one suitable check.
    # @spec LAYERED-VERIFY-021
    class Build
      Plan = Data.define(:checks, :exclusions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(checks:, exclusions: [], required_inputs: [], assumptions: [], resource_expectations: {}, residual_gaps: [])
        @checks = Array(checks)
        @exclusions = Array(exclusions)
        @required_inputs = Array(required_inputs)
        @assumptions = Array(assumptions)
        @resource_expectations = resource_expectations.to_h
        @residual_gaps = Array(residual_gaps)
      end

      def call
        raise ArgumentError, "a verification plan needs at least one selected check" if checks.empty?

        Plan.new(checks:, exclusions:, required_inputs:, assumptions:, resource_expectations:, residual_gaps:)
      end

      private

      attr_reader :assumptions, :checks, :exclusions, :required_inputs, :resource_expectations, :residual_gaps
    end
  end
end
