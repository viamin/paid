# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces the two deliberately separate report views from append-only
    # check evidence. An audit may finish with unresolved coverage; a report is
    # an observation, not a repair or an intent-approval action.
    class SynthesizeCoverage
      # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = Array(obligations)
      end

      def call
        reports = obligations.index_with { |obligation| report_for(obligation) }
        agent_run.update!(verification_result: agent_run.verification_result.merge("layered_verification_audit" => serialize(reports)))
        reports
      end

      private

      attr_reader :agent_run, :obligations

      def report_for(obligation)
        results = obligation.check_results.where(agent_run:).to_a
        { business_intent: view(results, business_producers), verification_coverage: view(results, verification_producers) }
      end

      def view(results, producers)
        selected = results.select { |result| result.producer.in?(producers) }
        { verdict: verdict_for(selected), checks: selected.map { |result| result.attributes.slice("producer", "execution_state", "obligation_coverage", "limitations", "evidence_ref", "input_revision") } }
      end

      def verdict_for(results)
        return "unresolved" if results.empty? || results.any? { |result| result.obligation_coverage == "unresolved" }
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }

        "supported"
      end

      def business_producers
        %w[business_formalization implementation_conformance semantic_audit]
      end

      def verification_producers
        LayeredVerificationCheckResult::PRODUCERS - business_producers
      end

      def serialize(reports)
        reports.transform_keys(&:id).transform_values(&:deep_stringify_keys)
      end
    end
  end
end
