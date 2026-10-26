# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Produces independent business-intent and verification-coverage report views.
    # @spec LAYERED-VERIFY-008 @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def call
        views = obligations.index_with { |obligation| view_for(obligation) }
        agent_run.update!(external_metadata: agent_run.external_metadata.merge("layered_verification_report" => views))
        views
      end

      private

      attr_reader :agent_run

      def obligations
        agent_run.project.layered_verification_obligations.where(id: audit_metadata.fetch("obligation_ids"))
      end

      def audit_metadata = agent_run.external_metadata.fetch("layered_verification_audit")

      def view_for(obligation)
        results = obligation.check_results.where(agent_run:).order(:created_at)
        coverage = results.pluck(:obligation_coverage)
        verdict = coverage.include?("contradicted") ? "contradicted" : coverage.include?("unresolved") ? "unresolved" : "supported"
        { "business_intent_validation" => business_view(results), "verification_coverage" => { "verdict" => verdict, "result_ids" => results.ids } }
      end

      def business_view(results)
        coverage = results.where(producer: %w[business_formalization semantic_audit]).pluck(:obligation_coverage)
        { "verdict" => coverage.include?("contradicted") ? "contradicted" : "unresolved" }
      end
    end
  end
end
