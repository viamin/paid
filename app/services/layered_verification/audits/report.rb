# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Report
      # @spec LAYERED-VERIFY-009
      def self.call(...) = new(...).call

      def initialize(obligations:, agent_run: nil)
        @obligations = Array(obligations)
        @agent_run = agent_run
      end

      def call
        {
          business_intent_validation: view_for(%w[business_formalization semantic_audit]),
          verification_coverage: view_for(LayeredVerificationCheckResult::PRODUCERS)
        }
      end

      private

      attr_reader :agent_run, :obligations

      def view_for(producers)
        obligations.index_with do |obligation|
          scope = obligation.check_results.where(producer: producers)
          scope = scope.where(agent_run:) if agent_run
          scope.order(created_at: :desc).map do |result|
            { producer: result.producer, execution_state: result.execution_state,
              coverage: result.obligation_coverage, limitations: result.limitations,
              evidence_ref: result.evidence_ref }
          end
        end
      end
    end
  end
end
