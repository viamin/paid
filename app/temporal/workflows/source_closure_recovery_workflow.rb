# frozen_string_literal: true

module Workflows
  # Rehydrates only the isolated LLM environment, then continues at the PR gate.
  class SourceClosureRecoveryWorkflow < BaseWorkflow
    ASSESSMENT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 15, max_interval: 2.minutes, backoff_coefficient: 2, max_attempts: 3
    )

    def execute(input) # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
      agent_run_id = input.fetch(:agent_run_id)
      project_id = input.fetch(:project_id)
      recovery_attempt = input.fetch(:recovery_attempt)
      run_activity(Activities::ProvisionContainerActivity, { agent_run_id: }, timeout: 60)
      return { agent_run_id:, waiting: true } unless assess_source_closure_or_park(agent_run_id)

      pr_result = run_activity(Activities::CreatePullRequestActivity, { agent_run_id: }, timeout: 120)
      finish_closeout(agent_run_id, project_id, pr_result) unless pr_result[:skipped] || pr_result[:pull_request_url].blank?
      { agent_run_id:, recovered: true }
    rescue => e
      raise_if_canceled!(e)
      run_cleanup_activity(Activities::ReleaseSourceClosureRecoveryClaimActivity,
        { agent_run_id:, recovery_attempt: }, timeout: 30)
      raise
    ensure
      if agent_run_id.present?
        run_cleanup_activity(Activities::CleanupContainerActivity, { agent_run_id: },
          start_to_close_timeout: 120, schedule_to_close_timeout: 300,
          retry_policy: AgentExecutionWorkflow::CLEANUP_RETRY_POLICY)
      end
    end

    private

    def assess_source_closure_or_park(agent_run_id)
      run_activity(Activities::AssessSourceClosureActivity, { agent_run_id: }, timeout: 120,
        retry_policy: ASSESSMENT_RETRY_POLICY)
      true
    rescue => e
      raise_if_canceled!(e)
      category = activity_failure_category(e)
      raise unless retry_exhausted_activity_error?(e) && category.in?(%w[timeout transport_error])

      run_activity(Activities::ParkSourceClosureRecoveryActivity,
        { agent_run_id:, category:, attempts: ASSESSMENT_RETRY_POLICY.max_attempts }, timeout: 30)
      false
    end

    def finish_closeout(agent_run_id, project_id, pr_result)
      reconcile_result = run_activity(Activities::ReconcilePartialCloseoutActivity, { agent_run_id: }, timeout: 120)
      run_activity(Activities::AdvancePartialCloseoutActivity, { agent_run_id: }, timeout: 30)
      publish_issue_result(agent_run_id, pr_result[:pull_request_url], reconcile_result[:gaps_remain])
      request_review(project_id, pr_result[:pull_request_number])
    end

    def publish_issue_result(agent_run_id, pull_request_url, gaps_remain)
      activity = gaps_remain ? Activities::PostPartialCloseoutEvidenceActivity : Activities::UpdateIssueWithPrActivity
      run_activity(activity, { agent_run_id:, pull_request_url: }, timeout: 30)
    end

    def request_review(project_id, pr_number)
      run_activity(Activities::RequestReviewActivity, { project_id:, pr_number: }, timeout: 60)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      Temporalio::Workflow.logger.warn(
        message: "agent_execution.review_bot_request_failed", project_id:, pr_number:, error: e.message
      )
    end
  end
end
