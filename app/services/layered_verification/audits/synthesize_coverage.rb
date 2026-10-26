# frozen_string_literal: true

module LayeredVerification
  module Audits
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-024
      def self.call(...) = new(...).call

      def initialize(obligations:)
        @obligations = obligations
      end

      def call
        coverage = obligations.map { |obligation| verdict_for(obligation) }
        { coverage:, inbox_required: coverage.any? { |entry| entry[:verdict] != "supported" } }
      end

      private

      attr_reader :obligations

      def verdict_for(obligation)
        verdict = results_for(obligation).map(&:obligation_coverage).then { |values| values.include?("contradicted") ? "contradicted" : values.include?("unresolved") ? "unresolved" : "supported" }
        { obligation_id: obligation.id, external_identity: obligation.external_identity,
          approval_state: obligation.approval_state, verdict:, check_result_ids: results_for(obligation).map(&:id) }
      end

      def results_for(obligation)
        obligation.check_results.order(:created_at).to_a
      end
    end
  end
end
