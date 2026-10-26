# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces two report-friendly views from immutable check evidence. A
    # check's execution status never substitutes for its coverage verdict.
    # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = obligations
      end

      def call
        obligations.map { |obligation| coverage_for(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def coverage_for(obligation)
        results = obligation.check_results.where(agent_run:).order(:created_at, :id).to_a
        verdict = verdict_for(results)
        create_finding(obligation, results) if verdict == "contradicted"
        {
          obligation_id: obligation.id,
          business_intent_validation: results.select { |result| result.producer.in?(%w[business_formalization semantic_audit]) }.map(&:id),
          verification_coverage: results.map(&:id),
          obligation_coverage: verdict
        }
      end

      def verdict_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def create_finding(obligation, results)
        result = results.find { |candidate| candidate.obligation_coverage == "contradicted" }
        claim_type = result.correspondence_claim&.claim_type || "business_to_spec"
        signature = result.agent_reported.fetch("cause_signature", "unresolved-correspondence")
        finding = LayeredVerificationFinding.create_or_find_by!(
          project: obligation.project, obligation:, correspondence_claim_type: claim_type, cause_signature: signature
        ) do |record|
          record.originating_audit_run = agent_run
          record.observed_behavior = result.evidence_summary.fetch("observed_behavior", "Contradictory evidence was recorded.")
          record.limitations = result.limitations
          record.decision_question = result.agent_reported.fetch("decision_question", "Which approved interpretation should govern?")
          record.source_passages = result.evidence_summary.fetch("source_passages", [])
          record.options = result.agent_reported.fetch("options", [])
        end
        finding.with_lock { finding.update!(observations: finding.observations + [ { "check_result_id" => result.id, "observed_at" => Time.current.iso8601 } ]) }
      end
    end
  end
end
