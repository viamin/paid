# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(audit_run:, obligations:)
        @audit_run = audit_run
        @obligations = Array(obligations)
      end

      def call
        coverage = obligations.index_with { |obligation| coverage_for(obligation) }
        audit_run.update!(verification_result: audit_run.verification_result.merge("coverage" => coverage.transform_keys(&:to_s)))
        coverage
      end

      private

      attr_reader :audit_run, :obligations

      def coverage_for(obligation)
        results = obligation.check_results.where(agent_run: audit_run)
        return "unresolved" if results.empty? || results.where(obligation_coverage: "unresolved").exists?
        return "contradicted" if results.where(obligation_coverage: "contradicted").exists?

        "supported"
      end
    end
  end
end
