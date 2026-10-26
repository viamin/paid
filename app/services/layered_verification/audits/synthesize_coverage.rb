# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call
      def initialize(agent_run:, obligations:) = (@agent_run = agent_run; @obligations = obligations)
      def call = obligations.index_with { |obligation| synthesize(obligation) }
      private
      attr_reader :agent_run, :obligations
      def synthesize(obligation)
        results = obligation.check_results.where(agent_run:)
        coverage = if results.where(obligation_coverage: "contradicted").exists?
          "contradicted"
        elsif results.exists? && results.where.not(obligation_coverage: "supported").none?
          "supported"
        else
          "unresolved"
        end
        { coverage:, result_ids: results.pluck(:id) }
      end
    end
  end
end
