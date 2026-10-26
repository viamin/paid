# frozen_string_literal: true

module LayeredVerification
  module Reports
    class Build
      # @spec LAYERED-VERIFY-006 @spec LAYERED-VERIFY-024
      def self.call(...)
        new(...).call
      end

      def initialize(run:)
        @run = run
      end

      def call
        metadata.merge(
          "run_id" => run.id,
          "status" => run.status,
          "initiating_user_id" => run.initiating_user_id,
          "business_intent_validation" => business_intent_validation,
          "verification_coverage" => verification_coverage,
          "waiting_reason" => waiting_reason
        )
      end

      private

      attr_reader :run

      def metadata
        run.external_metadata.fetch("layered_verification", {}).slice("obligation_ids", "target_revision", "budget_tokens", "plan")
      end

      def obligations
        @obligations ||= run.project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids", [])).includes(:correspondence_claims)
      end

      def results_by_obligation
        @results_by_obligation ||= LayeredVerificationCheckResult.where(agent_run: run).order(:created_at).group_by(&:obligation_id)
      end

      def business_intent_validation
        obligations.map do |obligation|
          {
            "external_identity" => obligation.external_identity,
            "scope" => obligation.scope_description,
            "approval_state" => obligation.approval_state,
            "external_revision" => obligation.external_revision,
            "correspondence_claims" => obligation.correspondence_claims.map(&:claim_type)
          }
        end
      end

      def verification_coverage
        obligations.map do |obligation|
          results = results_by_obligation.fetch(obligation.id, [])
          {
            "external_identity" => obligation.external_identity,
            "coverage" => coverage_for(results),
            "checks" => results.map { |result| check_payload(result) }
          }
        end
      end

      def coverage_for(results)
        return "unresolved" if results.empty?
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "unresolved" if results.any? { |result| result.obligation_coverage == "unresolved" }

        "supported"
      end

      def check_payload(result)
        result.attributes.slice("producer", "execution_state", "obligation_coverage", "limitations", "evidence_ref", "input_revision")
      end

      def waiting_reason
        run.error_message if run.status.in?(AgentRun::UNFINISHED_STATUSES)
      end
    end
  end
end
