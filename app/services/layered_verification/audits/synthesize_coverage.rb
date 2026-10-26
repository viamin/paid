# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      Result = Data.define(:coverage, :check_results)

      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(obligation:)
        @obligation = obligation
      end

      def call
        Result.new(coverage:, check_results: check_results)
      end

      private

      attr_reader :obligation

      def check_results = obligation.check_results.order(:created_at)

      def coverage
        return "contradicted" if check_results.exists?(obligation_coverage: "contradicted")
        return "unresolved" unless check_results.exists?(obligation_coverage: "supported")
        return "unresolved" if check_results.exists?(obligation_coverage: "unresolved")

        "supported"
      end
    end
  end
end
