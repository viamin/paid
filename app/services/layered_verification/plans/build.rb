# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Plan = Data.define(:selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(selected_checks:, omissions: [], required_inputs: [], assumptions: [], resource_expectations: {}, residual_gaps: [])
        @selected_checks = selected_checks
        @omissions = omissions
        @required_inputs = required_inputs
        @assumptions = assumptions
        @resource_expectations = resource_expectations
        @residual_gaps = residual_gaps
      end

      def call
        Plan.new(
          selected_checks: normalize_checks(selected_checks), omissions: normalize_omissions,
          required_inputs: Array(required_inputs), assumptions: Array(assumptions),
          resource_expectations: resource_expectations, residual_gaps: Array(residual_gaps)
        )
      end

      private

      attr_reader :selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps

      def normalize_checks(checks)
        Array(checks).map do |check|
          item = check.respond_to?(:to_h) ? check.to_h.stringify_keys : { "producer" => check.to_s }
          raise ArgumentError, "a selected check needs a producer and fit" if item["producer"].blank? || item["fit"].blank?

          item.slice("producer", "fit", "required_inputs", "assumptions", "limitations")
        end
      end

      def normalize_omissions
        Array(omissions).map do |omission|
          item = omission.respond_to?(:to_h) ? omission.to_h.stringify_keys : { "producer" => omission.to_s }
          raise ArgumentError, "an omitted check needs an explanation" if item["producer"].blank? || item["reason"].blank?

          item.slice("producer", "reason")
        end
      end
    end
  end
end
