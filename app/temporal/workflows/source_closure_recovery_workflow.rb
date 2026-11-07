# frozen_string_literal: true

module Workflows
  # Rehydrates only the isolated LLM environment, then continues at the PR gate.
  class SourceClosureRecoveryWorkflow < BaseWorkflow
    ASSESSMENT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 15, max_interval: 2.minutes, backoff_coefficient: 2, max_attempts: 3
    )

    def execute(input) # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
      agent_run_id = input.fetch(:agent_run_id)
      run_activity(Activities::ProvisionContainerActivity, { agent_run_id: }, timeout: 60)
      run_activity(Activities::AssessSourceClosureActivity, { agent_run_id: }, timeout: 120,
        retry_policy: ASSESSMENT_RETRY_POLICY)
      run_activity(Activities::CreatePullRequestActivity, { agent_run_id: }, timeout: 120)
      { agent_run_id:, recovered: true }
    rescue => e
      raise_if_canceled!(e)
      run_activity(Activities::ParkSourceClosureRecoveryActivity,
        { agent_run_id:, category: retry_exhausted_activity_error?(e) ? "timeout" : "transport_error", attempts: 3 }, timeout: 30)
      { agent_run_id:, waiting: true }
    ensure
      if agent_run_id.present?
        run_cleanup_activity(Activities::CleanupContainerActivity, { agent_run_id: },
          start_to_close_timeout: 120, schedule_to_close_timeout: 300,
          retry_policy: AgentExecutionWorkflow::CLEANUP_RETRY_POLICY)
      end
    end
  end
end
