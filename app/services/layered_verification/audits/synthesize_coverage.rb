# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      Result = Data.define(:obligation, :coverage, :check_results)

      def self.call(...) = new(...).call

      def initialize(agent_run:, obligation:)
        @agent_run = agent_run
        @obligation = obligation
      end

      def call
        results = obligation.check_results.where(agent_run:).order(:created_at).to_a
        Result.new(obligation:, coverage: coverage_for(results), check_results: results)
      end

      private

      attr_reader :agent_run, :obligation

      def coverage_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" } && results.all? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end
    end
  end
end
