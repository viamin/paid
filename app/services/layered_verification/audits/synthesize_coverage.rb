# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      Result = Data.define(:obligation, :coverage, :finding)

      def self.call(...)
        new(...).call
      end

      def initialize(audit_run:, obligation:)
        @audit_run = audit_run
        @obligation = obligation
      end

      def call
        coverage = coverage_for(results)
        Result.new(obligation, coverage, finding_for(coverage))
      end

      private

      attr_reader :audit_run, :obligation

      def results
        obligation.check_results.where(agent_run: audit_run).includes(:correspondence_claim).to_a
      end

      def coverage_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def finding_for(coverage)
        return unless coverage == "contradicted"

        result = results.find { |candidate| candidate.obligation_coverage == "contradicted" }
        LayeredVerificationFinding.record!(
          project: obligation.project,
          obligation:,
          audit_run:,
          correspondence_claim_type: result.correspondence_claim&.claim_type || "implementation_conformance",
          cause_signature: result.evidence_summary.fetch("cause_signature"),
          attributes: result.evidence_summary.symbolize_keys.merge(limitations: result.limitations),
          check_result: result
        )
      end
    end
  end
end
