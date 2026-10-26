# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Run
      # @spec LAYERED-VERIFY-021
      # @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(audit_run:)
        @audit_run = audit_run
      end

      def call
        obligations.each { |obligation| audit_obligation(obligation) }
        { obligation_count: obligations.count, coverage: coverage }
      end

      private

      attr_reader :audit_run

      def obligations
        audit_run.project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids")).includes(:correspondence_claims)
      end

      def audit_obligation(obligation)
        plan = Plans::Build.call(obligation:, available_artifacts: metadata.fetch("artifacts", []))
        plan.selected_checks.each { |check| record_unexecuted_check(obligation, check) }
        SynthesizeCoverage.call(audit_run:, obligation:)
      end

      def record_unexecuted_check(obligation, check)
        LayeredVerificationCheckResult.create!(
          obligation:,
          agent_run: audit_run,
          producer: producer_for(check),
          execution_state: "not_run",
          obligation_coverage: "unresolved",
          input_revision: { "target_revision" => metadata.fetch("target_revision") },
          limitations: "The selected #{check} check requires isolated execution evidence not available to this run."
        )
      end

      def producer_for(check)
        check.start_with?("correspondence:") ? "implementation_conformance" : check
      end

      def metadata
        audit_run.external_metadata.fetch("layered_verification_audit")
      end

      def coverage
        obligations.index_with { |obligation| SynthesizeCoverage.call(audit_run:, obligation:).coverage }
      end
    end
  end
end
