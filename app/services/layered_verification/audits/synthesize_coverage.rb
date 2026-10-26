# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Derives the report views and preserves a finding for every contradiction.
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      def self.call(...) = new(...).call

      def initialize(agent_run:, obligations:)
        @agent_run = agent_run
        @obligations = Array(obligations)
      end

      def call
        coverage = obligations.to_h { |obligation| [ obligation.id.to_s, coverage_for(obligation) ] }
        create_findings(coverage)
        LayeredVerificationAuditReport.upsert(
          { agent_run_id: agent_run.id, business_intent_validation: intent_view, verification_coverage: coverage, progress: { "status" => agent_run.status }, waiting_reasons: [], created_at: Time.current, updated_at: Time.current },
          unique_by: :index_layered_verification_audit_reports_on_agent_run_id
        )
        LayeredVerificationAuditReport.find_by!(agent_run:)
      end

      private

      attr_reader :agent_run, :obligations

      def coverage_for(obligation)
        values = obligation.check_results.where(agent_run:).pluck(:obligation_coverage)
        return "contradicted" if values.include?("contradicted")
        return "supported" if values.present? && values.all? { |value| value == "supported" }

        "unresolved"
      end

      def intent_view
        obligations.to_h { |obligation| [ obligation.id.to_s, obligation.approval_state ] }
      end

      def create_findings(coverage)
        obligations.each do |obligation|
          next unless coverage.fetch(obligation.id.to_s) == "contradicted"

          finding = LayeredVerificationFinding.find_or_create_by!(
            project: agent_run.project, obligation:, correspondence_claim: nil, cause_signature: "audit-contradiction"
          ) do |record|
            record.audit_run = agent_run
            record.observed_behavior = "A selected check contradicted this obligation."
            record.question = "Which authority or representation should be clarified before repair is requested?"
          end
          finding.observations.find_or_create_by!(audit_run: agent_run) { |observation| observation.evidence = { "coverage" => "contradicted" } }
        end
      end
    end
  end
end
