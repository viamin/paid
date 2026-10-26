# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-009
      def self.call(...) = new(...).call

      def initialize(obligations:, agent_run: nil)
        @obligations = Array(obligations)
        @agent_run = agent_run
      end

      def call
        obligations.index_with { |obligation| coverage_for(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def coverage_for(obligation)
        results = obligation.check_results.where(agent_run:).to_a if agent_run
        results ||= obligation.check_results.to_a
        return "unresolved" if results.empty?
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.any? { |result| result.obligation_coverage == "unresolved" }

        "supported"
      end
    end
  end
end
