# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      HOST_CHECKS = %w[ci security branch_protection code_review approved_intent_conformance].freeze

      def self.call(...) = new(...).call

      def initialize(obligations:, model_declared: false, semantic_audit: false)
        @obligations = obligations
        @model_declared = model_declared
        @semantic_audit = semantic_audit
      end

      def call
        selected = [ correspondence_check ]
        selected << formal_check if model_declared
        selected << semantic_check if semantic_audit
        {
          revision: Digest::SHA256.hexdigest(selected.to_json), selected_checks: selected,
          exclusions: exclusions, required_inputs: obligations.map(&:external_identity),
          assumptions: [], resource_expectations: {}, residual_gaps: exclusions.map { |item| item[:reason] },
          host_checks: HOST_CHECKS
        }
      end

      private

      attr_reader :obligations, :model_declared, :semantic_audit

      def correspondence_check
        { producer: "implementation_conformance", fit: "Declared correspondence claims can be assessed.", limitations: "Only declared claims are covered." }
      end

      def formal_check
        { producer: "formal_verification", fit: "A declared TLA+ model is available.", limitations: "Model bounds and assumptions limit conclusions." }
      end

      def semantic_check
        { producer: "semantic_audit", fit: "Explicitly requested bounded source read-through.", limitations: "Semantic assessment is evidence, not proof." }
      end

      def exclusions
        exclusions = []
        exclusions << { producer: "formal_verification", reason: "No declared formal model." } unless model_declared
        exclusions << { producer: "semantic_audit", reason: "Semantic audit was not selected for this bounded scope." } unless semantic_audit
        exclusions
      end
    end
  end
end
