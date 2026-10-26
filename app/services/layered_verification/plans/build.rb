# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      HOST_CHECKS = %w[ci security branch_protection code_review approved_intent_conformance].freeze

      def self.call(...) = new(...).call

      def initialize(obligations:, requested_checks: [], available_artifacts: {})
        @obligations = obligations
        @requested_checks = requested_checks.map(&:to_s)
        @available_artifacts = available_artifacts.stringify_keys
      end

      def call
        { checks: selected_checks, omissions: omissions, host_checks: HOST_CHECKS, residual_gaps: residual_gaps }
      end

      private

      attr_reader :available_artifacts, :obligations, :requested_checks

      def selected_checks
        checks = requested_checks.presence || [ "business_to_spec" ]
        checks << "formal_verification" if available_artifacts["tlc_model"].present?
        checks.uniq.map { |name| { name:, fit: fit_for(name), required_inputs: inputs_for(name) } }
      end

      def omissions
        return [] if available_artifacts["tlc_model"].present?

        [ { name: "formal_verification", reason: "No declared TLA+ model/configuration pair is available." } ]
      end

      def residual_gaps
        obligations.empty? ? [ "No resolved obligations were selected." ] : omissions.map { |omission| omission[:reason] }
      end

      def fit_for(name) = "Selected for the bounded obligation scope: #{name}."
      def inputs_for(name) = name == "formal_verification" ? %w[module config] : [ "source references" ]
    end
  end
end
