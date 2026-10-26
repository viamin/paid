# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations: nil)
        @agent_run = agent_run
        @obligations = obligations || agent_run.project.layered_verification_obligations.where(id: scoped_ids)
      end

      def call
        obligations.index_with { |obligation| synthesize(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def scoped_ids
        agent_run.external_metadata.dig("layered_verification", "obligation_ids") || []
      end

      def synthesize(obligation)
        results = obligation.check_results.where(agent_run:).order(:id).to_a
        coverage = coverage_for(results)
        finding_for(obligation, results) if coverage == "contradicted"
        { obligation_coverage: coverage, check_result_ids: results.map(&:id) }
      end

      def coverage_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def finding_for(obligation, results)
        contradictory = results.select { |result| result.obligation_coverage == "contradicted" }
        cause_signature = contradictory.map { |result| [ result.producer, result.evidence_ref ].join(":") }.sort.join("|")
        finding = LayeredVerificationFinding.find_or_create_by!(
          project: agent_run.project, obligation:, correspondence_claim_type: claim_type(contradictory), cause_signature:
        ) do |record|
          record.agent_run = agent_run
          record.source_passages = contradictory.map { |result| result.evidence_summary }
          record.observed_behavior = { "check_results" => contradictory.map(&:id) }
          record.check_limitations = contradictory.map(&:limitations)
          record.decision = { "question" => "Resolve the discrepancy before requesting repair.", "options" => [], "consequences" => [] }
        end
        finding.add_observation!(agent_run:, check_result_ids: contradictory.map(&:id))
      end

      def claim_type(results)
        results.filter_map { |result| result.correspondence_claim&.claim_type }.first || "unscoped"
      end
    end
  end
end
