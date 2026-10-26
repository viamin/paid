# frozen_string_literal: true

module LayeredVerification
  module Reports
    class Build
      # @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def call
        results = LayeredVerificationCheckResult.where(agent_run:).includes(:obligation, :correspondence_claim)
        {
          business_intent_validation: view(results, %w[business_formalization business_to_model business_to_spec]),
          verification_coverage: view(results, %w[behavioral_testing formal_verification mutation_testing implementation_conformance semantic_audit])
        }
      end

      private

      attr_reader :agent_run

      def view(results, producers)
        rows = results.select { |result| producers.include?(result.producer) || producers.include?(result.correspondence_claim&.claim_type) }
        rows.map { |result| { obligation: result.obligation.external_identity, coverage: result.obligation_coverage, state: result.execution_state, limitations: result.limitations, evidence: result.evidence_ref } }
      end
    end
  end
end
