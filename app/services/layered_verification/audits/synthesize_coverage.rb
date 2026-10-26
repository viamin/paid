# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = obligations
      end

      def call
        LayeredVerificationAuditReport.create!(
          agent_run:,
          business_intent_view: business_intent_view,
          verification_coverage_view: coverage_view,
          progress: { "state" => "completed", "obligation_count" => obligations.size }
        )
      end

      private

      attr_reader :agent_run, :obligations

      def business_intent_view
        obligations.index_with { |obligation| obligation.scope_description }.transform_keys(&:external_identity)
      end

      def coverage_view
        obligations.index_with { |obligation| coverage_for(obligation) }.transform_keys(&:external_identity)
      end

      def coverage_for(obligation)
        results = obligation.check_results.where(agent_run:)
        verdict = verdict_for(results)
        record_finding(obligation, results) if verdict == "contradicted"
        verdict
      end

      def verdict_for(results)
        return "contradicted" if results.where(obligation_coverage: "contradicted").exists?
        return "supported" if results.exists? && results.where.not(obligation_coverage: "supported").none?

        "unresolved"
      end

      def record_finding(obligation, results)
        result = results.find_by!(obligation_coverage: "contradicted")
        LayeredVerificationFinding.record!(
          obligation:, audit_run: agent_run, check_result: result, correspondence_claim: result.correspondence_claim,
          cause_signature: result.evidence_summary.fetch("cause_signature", "check-result-#{result.id}"),
          details: { "source_passages" => result.evidence_summary["source_passages"], "observed_behavior" => result.evidence_summary["observed_behavior"], "limitations" => result.limitations }
        )
      end
    end
  end
end
