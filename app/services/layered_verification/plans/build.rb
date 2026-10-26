# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Builds an explicit, inspectable plan. Selection inputs are supplied by the
    # bounded planner; this object never infers semantic suitability from text.
    # @spec LAYERED-VERIFY-021
    class Build
      Plan = Data.define(:selected_checks, :fit, :exclusions, :required_inputs, :assumptions, :resource_expectations, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(obligations:, available_artifacts: {})
        @obligations = obligations
        @available_artifacts = available_artifacts.stringify_keys
      end

      def call
        Plan.new(
          selected_checks: selected_checks,
          fit: selected_checks.index_with { |check| "Selected for declared available artifacts and scoped obligations." },
          exclusions: exclusions,
          required_inputs: required_inputs,
          assumptions: [ "Artifact declarations accurately describe the selected revision." ],
          resource_expectations: { "check_count" => selected_checks.size },
          residual_gaps: residual_gaps
        )
      end

      private

      attr_reader :available_artifacts, :obligations

      def selected_checks
        @selected_checks ||= begin
          checks = [ "implementation_conformance" ] if available_artifacts["specs"] || obligations.any? { |obligation| obligation.correspondence_claims.any? }
          checks ||= [ "linkage_freshness" ]
          checks << "formal_verification" if available_artifacts["tla_model"]
          checks.uniq
        end
      end

      def exclusions
        LayeredVerificationCheckResult::PRODUCERS.index_with do |producer|
          next "selected" if selected_checks.include?(producer)

          "No declared artifact or bounded command supports this check for the requested scope."
        end
      end

      def required_inputs = { "obligation_count" => obligations.size, "artifacts" => available_artifacts.keys }
      def residual_gaps = exclusions.reject { |_check, reason| reason == "selected" }
    end
  end
end
