# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  class_attribute :notification_subsystem, default: "general"
  class_attribute :max_attempts, default: 1

  rescue_from(StandardError) do |exception|
    notify_terminal_failure(exception) if executions >= self.class.max_attempts
    raise exception
  end

  around_perform do |job, block|
    Database::QueryMonitor.instrument("job", job_class: job.class.name) do
      block.call
    end
  end

  around_perform :with_tenant_context

  def notification_project_id
    nil
  end

  # Report a terminal job failure to the exception notifier. Used by the base
  # rescue_from hook for non-retried errors, and by retry_on blocks when a retry
  # policy is exhausted — retry_on registers a more specific handler that
  # intercepts those errors before the base hook, so the final attempt must
  # report explicitly (it then re-raises so the adapter still marks the job
  # failed). HandleExceptionJob is skipped to avoid an infinite notify loop.
  def notify_terminal_failure(exception)
    return if is_a?(HandleExceptionJob)

    Paid::ExceptionNotifier.new.call(
      exception,
      data: {
        account: notification_account,
        subsystem: self.class.notification_subsystem,
        project_id: notification_project_id
      }
    )
  end

  private

  # Resolve the tenant account for the notifier. The rescue_from handler runs
  # in perform_now's rescue clause, after the with_tenant_context around_perform
  # has already restored Current.account — so on a GoodJob worker thread it is
  # nil by the time we notify. Re-resolve and pass it explicitly so terminal
  # failures still produce incidents. Defensive: never let account lookup mask
  # the original exception.
  def notification_account
    TenantContext.with_system_access { tenant_account }
  rescue StandardError
    nil
  end

  def with_tenant_context(&block)
    account = TenantContext.with_system_access { tenant_account }
    return TenantContext.with(account, &block) if account

    TenantContext.with_system_access(&block)
  end

  def tenant_account
    case self
    when DashboardBroadcastJob
      Account.find_by(id: arguments.first)
    when LiveDashboardBroadcastJob
      Account.find_by(id: arguments.first)
    when GithubTokenValidationJob
      GithubToken.find_by(id: arguments.first)&.account
    when StyleGuideCompressionJob
      StyleGuide.find_by(id: arguments.first)&.account
    when ServiceContainerMetricsCollectionJob
      ServiceContainer.find_by(id: arguments.first)&.account
    when QdrantCollectionCleanupJob
      Account.find_by(id: arguments.second)
    when HandleExceptionJob
      hash = arguments.first
      return unless hash.is_a?(Hash)

      Account.find_by(id: hash[:account_id] || hash["account_id"])
    when AbTestAnalysisJob
      AbTest.includes(:prompt).find_by(id: arguments.first)&.prompt&.account
    else
      tenant_account_from_project || tenant_account_from_agent_run
    end
  end

  def tenant_account_from_project
    project_id = project_id_argument
    return unless project_id

    Project.find_by(id: project_id)&.account
  end

  def tenant_account_from_agent_run
    agent_run_id = agent_run_id_argument
    return unless agent_run_id

    AgentRun.includes(:project).find_by(id: agent_run_id)&.project&.account
  end

  def project_id_argument
    return arguments.first if project_id_first?
    hash = arguments.first
    return unless hash.is_a?(Hash)

    hash[:project_id] || hash["project_id"]
  end

  def agent_run_id_argument
    return arguments.first if agent_run_id_first?
    hash = arguments.first
    return unless hash.is_a?(Hash)

    hash[:agent_run_id] || hash["agent_run_id"]
  end

  def project_id_first?
    [
      AutoReleaseEvaluationJob,
      DependabotAutoMergeJob,
      DependencyBackfillJob,
      EmbedChunksJob,
      EnqueueKnowledgeCollectionJob,
      ProjectConventions::OpenHookGuardrailPullRequestJob,
      PoolReplenishmentJob,
      RunCollectorsJob,
      StyleGuideExtractionJob
    ].any? { |job_class| is_a?(job_class) }
  end

  def agent_run_id_first?
    [
      AgentRunCancellationJob,
      AgentRunResourceJanitorJob,
      AnomalyDetectionJob,
      ContainerMetricsCollectionJob,
      DiagnoseErrorJob,
      FailureRecoveryDecisionJob,
      HumanFeedbackCollectionJob,
      QualityMetricsCollectionJob,
      RetryTimedOutIssueGoalJob
    ].any? { |job_class| is_a?(job_class) }
  end
end
