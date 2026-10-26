# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      Coverage = Data.define(:obligation, :verdict, :results)

      def self.call(...) = new(...).call

      def initialize(obligation:, results: nil)
        @obligation = obligation
        @results = results
      end

      def call
        Coverage.new(obligation, verdict, results)
      end

      private

      attr_reader :obligation

      def results = @results ||= obligation.check_results.order(:created_at).to_a

      def verdict
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.empty? || results.any? { |result| result.obligation_coverage == "unresolved" }

        "supported"
      end
    end
  end
end
