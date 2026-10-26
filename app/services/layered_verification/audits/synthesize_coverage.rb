# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = obligations
      end

      def call
        obligations.index_with { |obligation| verdict_for(obligation) }
      end

      private

      attr_reader :agent_run, :obligations

      def verdict_for(obligation)
        coverages = obligation.check_results.where(agent_run:).pluck(:obligation_coverage)
        return "contradicted" if coverages.include?("contradicted")
        return "supported" if coverages.present? && coverages.all?("supported")

        "unresolved"
      end
    end
  end
end
