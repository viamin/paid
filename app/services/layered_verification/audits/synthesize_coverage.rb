# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligation:)
        @agent_run = agent_run
        @obligation = obligation
      end

      def call
        results = obligation.check_results.where(agent_run:)
        verdict = results.where(obligation_coverage: "contradicted").exists? ? "contradicted" :
          (results.exists? && results.where(obligation_coverage: "unresolved").none? ? "supported" : "unresolved")
        record_finding! if verdict == "contradicted"
        { obligation_id: obligation.id, obligation_coverage: verdict, results: results.ids }
      end

      private

      attr_reader :agent_run, :obligation

      def record_finding!
        result = obligation.check_results.where(agent_run:, obligation_coverage: "contradicted").first
        claim = result.correspondence_claim
        LayeredVerificationFinding.record!(
          project: obligation.project, obligation:, correspondence_claim: claim,
          cause_signature: Digest::SHA256.hexdigest([ obligation.external_identity, claim&.claim_type, result.evidence_ref ].join(":")),
          attributes: { source_passages: result.evidence_summary, observed_behavior: result.agent_reported, limitations: result.limitations },
          observation: { agent_run:, check_result: result, details: { input_revision: result.input_revision } }
        )
      end
    end
  end
end
