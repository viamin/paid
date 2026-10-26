# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run, @obligations = agent_run, obligations
      end

      def call
        findings = obligations.filter_map { |obligation| finding_for(obligation) }
        { coverage: obligations.index_with { |obligation| coverage_for(obligation) }.transform_keys(&:id), findings: findings }
      end

      private

      attr_reader :agent_run, :obligations

      def results_for(obligation) = obligation.check_results.where(agent_run: agent_run)

      def coverage_for(obligation)
        coverages = results_for(obligation).pluck(:obligation_coverage)
        return "contradicted" if coverages.include?("contradicted")
        return "supported" if coverages.present? && coverages.all?("supported")

        "unresolved"
      end

      def finding_for(obligation)
        return if coverage_for(obligation) == "supported"

        result = results_for(obligation).order(:id).first
        LayeredVerificationFinding.record!(
          project: agent_run.project, obligation:, correspondence_claim_type: result&.correspondence_claim&.claim_type || "unmapped",
          cause_signature: "#{coverage_for(obligation)}:#{result&.producer || 'no_check'}",
          observation: {
            agent_run:, check_result: result, observed_behavior: "Audit coverage is #{coverage_for(obligation)}.",
            limitations: result&.limitations || "No completed check result was available for this obligation.",
            source_passages: result&.evidence_summary || {}
          }
        )
      end
    end
  end
end
