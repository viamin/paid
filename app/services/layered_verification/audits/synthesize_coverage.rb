# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(audit_run:, obligation:)
        @audit_run = audit_run
        @obligation = obligation
      end

      def call
        results = obligation.check_results.where(agent_run: audit_run).order(:created_at)
        verdict = verdict_for(results)
        finding = record_finding(results) if verdict == "contradicted"
        { obligation_id: obligation.id, obligation_coverage: verdict, check_result_ids: results.ids, finding_id: finding&.id }
      end

      private

      attr_reader :audit_run, :obligation

      def verdict_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" } && results.all? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def record_finding(results)
        result = results.find { |item| item.obligation_coverage == "contradicted" }
        claim = result.correspondence_claim
        LayeredVerificationFinding.record_observation!(
          project: obligation.project, obligation:, correspondence_claim: claim, audit_run:,
          correspondence_claim_type: claim&.claim_type || "direct_obligation", cause_signature: result.evidence_ref.presence || "check-result-#{result.id}",
          check_result: result, source_passages: claim&.source_reference || obligation.external_identity,
          observed_behavior: result.evidence_summary.fetch("observed_behavior", "A selected check contradicted this obligation."),
          limitations: result.limitations, question: "How should this discrepancy be resolved?",
          options: [], links: { "audit_run_id" => audit_run.id, "check_result_id" => result.id }, evidence: result.evidence_summary
        )
      end
    end
  end
end
