# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces one scoped verdict without changing historical check rows.
    # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(obligation:, agent_run:, results:)
        @obligation, @agent_run, @results = obligation, agent_run, results
      end

      def call
        verdict = coverage_verdict
        create_finding if verdict == "contradicted"
        verdict
      end

      private

      attr_reader :agent_run, :obligation, :results

      def coverage_verdict
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def create_finding
        result = results.find { |candidate| candidate.obligation_coverage == "contradicted" }
        claim = result.correspondence_claim
        finding = LayeredVerificationFinding.find_or_create_by!(project: obligation.project, obligation:,
          correspondence_claim_type: claim&.claim_type || "none", cause_signature: cause_signature(result)) do |record|
            record.correspondence_claim = claim
            record.agent_run = agent_run
            record.source_passages = Array(result.evidence_summary["source_passages"])
            record.observed_behavior = result.evidence_summary["observed_behavior"].presence || "A selected check contradicted this obligation."
            record.question = "What should happen for this unresolved discrepancy?"
            record.options = [ "Clarify canonical intent", "Request a separately authorized repair", "Defer with reason" ]
            record.consequences = [ "Discussion, acknowledgement, and deferral leave the discrepancy unresolved." ]
          end
        finding.observations.create!(agent_run:, check_result: result, evidence: result.evidence_summary)
      end

      def cause_signature(result)
        result.evidence_summary["cause_signature"].presence || Digest::SHA256.hexdigest([ obligation.external_identity, result.producer, result.evidence_ref ].join("\u0000"))
      end
    end
  end
end
