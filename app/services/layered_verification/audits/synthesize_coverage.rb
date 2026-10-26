# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces a coverage view without turning successful local checks into correspondence proof.
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      Coverage = Data.define(:obligation, :verdict, :results)

      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = Array(obligations)
      end

      def call
        obligations.map { |obligation| coverage_for(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def coverage_for(obligation)
        results = obligation.check_results.where(agent_run:).order(:id).to_a
        verdict = if results.any? { |result| result.obligation_coverage == "contradicted" }
          "contradicted"
        elsif results.any? { |result| result.obligation_coverage == "supported" }
          "supported"
        else
          "unresolved"
        end
        Coverage.new(obligation:, verdict:, results:)
      end
    end
  end
end
