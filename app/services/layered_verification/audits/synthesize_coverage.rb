# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(obligations:, check_results:)
        @obligations = Array(obligations)
        @check_results = Array(check_results)
      end

      def call
        obligations.to_h { |obligation| [ obligation.id, coverage_for(obligation) ] }
      end

      private

      attr_reader :check_results, :obligations

      def coverage_for(obligation)
        results = check_results.select { |result| result.obligation_id == obligation.id }
        { "obligation_coverage" => verdict_for(results), "check_result_ids" => results.map(&:id) }
      end

      def verdict_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.empty? || results.any? { |result| result.obligation_coverage == "unresolved" }

        "supported"
      end
    end
  end
end
