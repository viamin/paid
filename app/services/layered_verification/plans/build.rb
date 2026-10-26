# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Builds the durable, bounded plan that is shown before an audit is dispatched.
    # @spec LAYERED-VERIFY-021
    class Build
      HOST_CONTROLS = [ "CI", "security", "branch protection", "code review", "approved-intent conformance" ].freeze
      Plan = Data.define(:selected_checks, :exclusions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps, :host_controls)

      def self.call(...) = new(...).call

      def initialize(checks:, exclusions:, required_inputs:, assumptions:, resource_expectations:)
        @checks = Array(checks)
        @exclusions = Array(exclusions)
        @required_inputs = Array(required_inputs)
        @assumptions = Array(assumptions)
        @resource_expectations = resource_expectations.to_h
      end

      def call
        Plan.new(
          selected_checks: checks.map { |check| check.to_h.deep_stringify_keys },
          exclusions: exclusions.map { |exclusion| exclusion.to_h.deep_stringify_keys },
          required_inputs:,
          assumptions:,
          resource_expectations:,
          residual_gaps: residual_gaps,
          host_controls: HOST_CONTROLS
        )
      end

      private

      attr_reader :checks, :exclusions, :required_inputs, :assumptions, :resource_expectations

      def residual_gaps
        exclusions.filter_map { |exclusion| exclusion.to_h["reason"] || exclusion.to_h[:reason] }
      end
    end
  end
end
