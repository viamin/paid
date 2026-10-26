# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces independent intent and verification views from append-only check
    # evidence. Findings are emitted only for contradictions or uncertainty.
    # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      View = Data.define(:obligation_id, :business_intent, :verification_coverage, :results)

      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = Array(obligations)
      end

      def call
        views = obligations.map { |obligation| view_for(obligation) }
        agent_run.update!(verification_result: agent_run.verification_result.merge("layered_verification" => { "views" => views.map(&:to_h) }))
        views
      end

      private

      attr_reader :agent_run, :obligations

      def view_for(obligation)
        results = obligation.check_results.where(agent_run:).order(:id).to_a
        coverage = verdict(results)
        record_finding(obligation, results, coverage) unless coverage == "supported"
        View.new(obligation.id, obligation.approval_state, coverage, results.map(&:id))
      end

      def verdict(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def record_finding(obligation, results, coverage)
        result = results.find { |candidate| candidate.obligation_coverage == coverage } || results.first
        LayeredVerificationFinding.record!(
          attributes: {
            project: obligation.project, obligation:, agent_run:, correspondence_claim: result&.correspondence_claim,
            correspondence_claim_type: result&.correspondence_claim&.claim_type || "business_to_spec",
            cause_signature: "#{coverage}:#{obligation.external_identity}", source_passages: [], claims: [],
            observed_behavior: result&.evidence_summary&.fetch("observed_behavior", "No supporting evidence was recorded."),
            limitations: result&.limitations || "No check result was recorded for this obligation.",
            question: "How should this discrepancy be resolved?", options: [], owner_actions: [ "Review audit evidence" ]
          },
          observation: { "agent_run_id" => agent_run.id, "check_result_ids" => results.map(&:id), "coverage" => coverage, "recorded_at" => Time.current.iso8601 }
        )
      end
    end
  end
end
