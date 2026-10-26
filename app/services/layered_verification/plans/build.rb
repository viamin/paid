# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      Result = Data.define(:selected_checks, :omissions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...)
        new(...).call
      end

      def initialize(obligation:, available_artifacts:, requested_checks: [])
        @obligation = obligation
        @available_artifacts = Array(available_artifacts).map(&:to_s)
        @requested_checks = Array(requested_checks).map(&:to_s)
      end

      def call
        Result.new(
          selected_checks: selected_checks,
          omissions: omissions,
          required_inputs: available_artifacts,
          assumptions: correspondence_claims.map(&:assumptions),
          resource_expectations: {},
          residual_gaps: omissions.values
        )
      end

      private

      attr_reader :available_artifacts, :obligation, :requested_checks

      def selected_checks
        return requested_checks if requested_checks.present?

        correspondence_claims.map { |claim| "correspondence:#{claim.claim_type}" }.presence || [ "linkage_freshness" ]
      end

      def omissions
        omitted = {}
        omitted["formal_verification"] = "No declared formal model is available." unless available_artifacts.include?("formal_model")
        omitted["semantic_audit"] = "Not selected for this bounded obligation." unless selected_checks.include?("semantic_audit")
        omitted
      end

      def correspondence_claims
        obligation.correspondence_claims.to_a
      end
    end
  end
end
