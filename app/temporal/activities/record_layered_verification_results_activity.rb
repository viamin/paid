# frozen_string_literal: true

module Activities
  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
  class RecordLayeredVerificationResultsActivity < BaseActivity
    activity_name "RecordLayeredVerificationResults"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      LayeredVerification::Audits::IngestResults.call(agent_run:)
      { agent_run_id: agent_run.id, check_result_count: LayeredVerificationCheckResult.where(agent_run:).count }
    end
  end
end
