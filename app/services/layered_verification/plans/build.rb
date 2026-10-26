# frozen_string_literal: true

module LayeredVerification
  module Plans
    # Builds an auditable, capability-driven plan. It deliberately chooses no
    # semantic check when the request has no semantic inputs.
    class Build
      # @spec LAYERED-VERIFY-021
      def self.call(...) = new(...).call

      def initialize(obligations:, sources:, model_declared: false)
        @obligations = obligations
        @sources = sources
        @model_declared = model_declared
      end

      def call
        {
          selected_checks: selected_checks,
          fit: fit,
          omissions: omissions,
          required_inputs: { "sources" => sources, "obligation_ids" => obligations.map(&:id) },
          assumptions: [ "Checks are bounded to the supplied scope and target revision." ],
          resource_expectations: { "minimum_layers" => 0 },
          residual_gaps: residual_gaps
        }
      end

      private

      attr_reader :obligations, :sources, :model_declared

      def selected_checks
        checks = claim_types
        checks << "formal_verification" if model_declared
        checks << "linkage_freshness" if checks.empty?
        checks
      end

      def claim_types = obligations.flat_map { |obligation| obligation.correspondence_claims.pluck(:claim_type) }.uniq

      def fit = selected_checks.index_with { |check| "Selected because declared scope has #{check.tr('_', ' ')} evidence." }

      def omissions
        omissions = []
        omissions << { check: "formal_verification", reason: "No declared formal model." } unless model_declared
        omissions << { check: "semantic_audit", reason: "No semantic review was requested or required by available artifacts." } if sources.empty?
        omissions
      end

      def residual_gaps
        [ "Only declared correspondence claims can be assessed; undeclared mappings remain uncertain." ]
      end
    end
  end
end
