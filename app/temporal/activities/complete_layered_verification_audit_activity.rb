# frozen_string_literal: true

module Activities
  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-024
  class CompleteLayeredVerificationAuditActivity < BaseActivity
    class MissingCoverageError < StandardError; end

    activity_name "CompleteLayeredVerificationAudit"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      return result(agent_run, stored_coverage(agent_run)) if agent_run.finished?

      track_phase(agent_run_id: agent_run.id, phase_key: "complete_layered_verification_audit", phase_group: "post", agent_run:) do
        coverage = stored_coverage(agent_run) || LayeredVerification::Audits::RecordResults.call(agent_run:)
        expected_ids = Array(agent_run.external_metadata.dig("layered_verification", "obligation_ids")).map(&:to_s).uniq
        unless expected_ids.any? && expected_ids.sort == coverage.keys.sort
          raise MissingCoverageError, "Every admitted audit obligation requires scoped coverage"
        end
        LayeredVerification::ReviewPackages::Capture.call(agent_run:)
        completed = agent_run.complete!
        ProcessRunQueueJob.perform_later if completed
        result(agent_run, coverage)
      end
    end

    private

    def stored_coverage(agent_run)
      metadata = agent_run.external_metadata.fetch("layered_verification", {})
      metadata["coverage"]&.transform_values(&:symbolize_keys) if metadata.key?("coverage")
    end

    def result(agent_run, coverage)
      { agent_run_id: agent_run.id, success: agent_run.successful?, coverage: coverage || {} }
    end
  end
end
