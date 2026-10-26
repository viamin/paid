# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = obligations
      end

      def call
        obligations.index_with { |obligation| synthesize(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def synthesize(obligation)
        results = obligation.check_results.where(agent_run:).order(:created_at).to_a
        coverage = coverage_for(results)
        result = record_summary(obligation, coverage, results)
        record_finding(obligation, result) if coverage == "contradicted"
        coverage
      end

      def coverage_for(results)
        return "unresolved" if results.empty?
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def record_summary(obligation, coverage, results)
        LayeredVerificationCheckResult.create!(
          obligation:,
          agent_run:,
          producer: "implementation_conformance",
          execution_state: "completed",
          obligation_coverage: coverage,
          input_revision: { "external_revision" => obligation.external_revision },
          evidence_summary: { "contributing_result_ids" => results.map(&:id) },
          limitations: "Synthesized from the recorded bounded check results."
        )
      end

      def record_finding(obligation, result)
        LayeredVerification::Findings::Record.call(
          obligation:, agent_run:, check_result: result,
          correspondence_claim_type: correspondence_type(obligation),
          cause_signature: "contradicted-correspondence",
          details: { "claims" => obligation.correspondence_claims.map(&:source_reference),
            "observed_behavior" => "Recorded checks contradict this scoped correspondence.",
            "question" => "What should be corrected or clarified for this discrepancy?" }
        )
      end

      def correspondence_type(obligation)
        obligation.correspondence_claims.first&.claim_type || "business_to_spec"
      end
    end
  end
end
