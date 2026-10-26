# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Keeps the semantic selection (normally supplied by agent_harness) explicit
    # and validates the mechanically enforceable audit-plan contract.
    # @spec LAYERED-VERIFY-021
    class Build
      Plan = Data.define(:selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(selected_checks:, omissions:, required_inputs:, assumptions:, resource_expectations:, residual_gaps:)
        @selected_checks, @omissions, @required_inputs, @assumptions, @resource_expectations, @residual_gaps = selected_checks, omissions, required_inputs, assumptions, resource_expectations, residual_gaps
      end

      def call
        raise ArgumentError, "every unselected check needs an explained omission" unless omissions.is_a?(Array)

        Plan.new(selected_checks: Array(selected_checks), omissions:, required_inputs: Array(required_inputs),
          assumptions: Array(assumptions), resource_expectations: resource_expectations || {}, residual_gaps: Array(residual_gaps))
      end

      private

      attr_reader :selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps
    end
  end
end
