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
        return "supported" if results.any? && results.all? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def finding_for(obligation, results)
        contradictory = results.select { |result| result.obligation_coverage == "contradicted" }
        contradictory.group_by { |result| [ claim_type(result), result.cause_signature ] }.each_value do |conflict_results|
          persist_finding(obligation, conflict_results)
        end
      end

      def persist_finding(obligation, contradictory)
        correspondence_claim_type = claim_type(contradictory.first)
        cause_signature = contradictory.first.cause_signature
        finding = LayeredVerificationFinding.find_or_create_by!(
          project: agent_run.project, obligation_external_identity: obligation.external_identity,
          correspondence_claim_type:, cause_signature:
        ) do |record|
          record.obligation = obligation
          record.agent_run = agent_run
          record.source_passages = contradictory.map { |result| result.evidence_summary }
          record.observed_behavior = { "check_results" => contradictory.map(&:id) }
          record.check_limitations = contradictory.map(&:limitations)
          record.decision = {
            "question" => "How should this discrepancy be handled?",
            "options" => %w[request_repair approve_clarification defer],
            "consequences" => [ "Repair requires separate authorization; this decision does not start one." ]
          }
        end
        finding.add_observation!(
          obligation:, agent_run:, check_result_ids: contradictory.map(&:id),
          evidence: {
            source_passages: contradictory.map(&:evidence_summary),
            observed_behavior: { "check_results" => contradictory.map(&:id) },
            check_limitations: contradictory.map(&:limitations)
          }
        )
      end

      def claim_type(result)
        result.correspondence_claim&.claim_type || "unscoped"
      end
    end
  end
end
