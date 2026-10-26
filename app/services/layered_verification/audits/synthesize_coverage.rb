# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces a separate, per-obligation coverage view without equating a
    # completed command with support for the obligation.
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      View = Data.define(:obligation, :coverage, :check_results)

      def self.call(...)
        new(...).call
      end

      def initialize(obligations:, agent_run: nil)
        @obligations = obligations
        @agent_run = agent_run
      end

      def call
        obligations.map { |obligation| view_for(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def view_for(obligation)
        results = obligation.check_results.then { |scope| agent_run ? scope.where(agent_run:) : scope }.to_a
        View.new(obligation, coverage_for(results), results)
      end

      def coverage_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.empty? || results.any? { |result| result.obligation_coverage == "unresolved" }

        "supported"
      end
    end
  end
end
