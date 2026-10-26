# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces an explicit coverage verdict for every requested obligation; no
    # missing result is treated as support.
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations: nil)
        @agent_run = agent_run
        @obligations = obligations
      end

      def call
        scoped_obligations.map { |obligation| synthesize(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def scoped_obligations
        obligations || agent_run.project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids"))
      end

      def metadata = agent_run.external_metadata.fetch("layered_verification_audit")

      def synthesize(obligation)
        results = obligation.check_results.where(agent_run:).order(:created_at).to_a
        coverage = verdict(results)
        { obligation:, coverage:, results:, finding: finding_for(obligation, results, coverage) }
      end

      def verdict(results)
        return "unresolved" if results.empty?
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.any? { |result| result.obligation_coverage == "unresolved" || result.execution_state != "completed" }

        "supported"
      end

      def finding_for(obligation, results, coverage)
        return unless coverage == "contradicted"

        result = results.reverse.find { |row| row.obligation_coverage == "contradicted" }
        claim_type = result.correspondence_claim&.claim_type || "implementation_conformance"
        signature = result.agent_reported.fetch("cause_signature")
        finding = LayeredVerificationFinding.find_or_create_by!(project: agent_run.project, obligation:,
          correspondence_claim_type: claim_type, cause_signature: signature) do |row|
          row.originating_audit_run = agent_run
          row.detail = result.evidence_summary
        end
        LayeredVerificationFindingObservation.find_or_create_by!(finding:, check_result: result) do |row|
          row.agent_run = agent_run
          row.detail = result.evidence_summary
        end
        finding
      end
    end
  end
end
