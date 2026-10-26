# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Converts immutable check rows into an explicit obligation verdict. A
    # contradiction is durable and remains open until later fresh evidence.
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      Result = Data.define(:verdict, :finding)

      def self.call(...) = new(...).call

      def initialize(obligation:, check_results:, agent_run: nil)
        @obligation = obligation
        @check_results = check_results
        @agent_run = agent_run
      end

      def call
        verdict = verdict_for(check_results)
        finding = verdict == "contradicted" ? record_finding : nil
        Result.new(verdict:, finding:)
      end

      private

      attr_reader :agent_run, :check_results, :obligation

      def verdict_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def record_finding
        result = check_results.find { |candidate| candidate.obligation_coverage == "contradicted" }
        LayeredVerificationFinding.record!(
          obligation:, correspondence_claim: result.correspondence_claim, agent_run:,
          cause_signature: "#{result.producer}:#{result.evidence_ref.presence || result.id}",
          attributes: { source_passages: result.evidence_summary, observed_behavior: result.agent_reported,
                        limitations: result.limitations, observation: { "check_result_id" => result.id } }
        )
      end
    end
  end
end
