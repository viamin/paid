# frozen_string_literal: true

require "timeout"

class ApplicationJob < ActiveJob::Base
  # Raised when a job exceeds its configured perform_timeout. Intentionally
  # inherits from StandardError (NOT Timeout::Error) so that existing
  # `rescue Timeout::Error` handlers in the call stacks — auth_health.rb,
  # base_collector.rb, etc. — do not silently swallow the job-level abort
  # signal. The base `rescue_from(StandardError)` hook in this class is what
  # catches it, marks the job terminal, and reports an incident.
  class PerformTimeoutError < StandardError; end

  class_attribute :notification_subsystem, default: "general"
  class_attribute :max_attempts, default: 1

  # Optional wall-clock ceiling (in seconds) for a single perform; nil disables
  # it. Opt in per job as a backstop for work that can block indefinitely on
  # external I/O (containers, network, git). Under GoodJob's :async_server mode
  # jobs run on threads inside Puma, so a job that hangs forever also pins the
  # code-reloader's load interlock and stalls every web request — this bound
  # guarantees such a job eventually fails instead of hanging the process.
  class_attribute :perform_timeout, default: nil

  rescue_from(StandardError) do |exception| # @spec EXCEPTION-NOTIFY-003
    notify_terminal_failure(exception) if executions >= self.class.max_attempts
    raise exception
  end

  around_perform do |job, block|
    Database::QueryMonitor.instrument("job", job_class: job.class.name) do
      block.call
    end
  end

  around_perform :with_tenant_context

  # IMPORTANT: must remain the last around_perform registration in this class.
  # ActiveJob callbacks run in registration order, innermost last — adding
  # another around_perform after this line silently places it inside the
  # timeout ceiling. Keep the timeout scoped to the actual job work, not the
  # tenant/query-monitor setup around it.
  around_perform :with_perform_timeout

  def notification_project_id
    nil
  end

  # Report a terminal job failure to the exception notifier. Used by the base
  # rescue_from hook for non-retried errors, and by retry_on blocks when a retry
  # policy is exhausted — retry_on registers a more specific handler that
  # intercepts those errors before the base hook, so the final attempt must
  # report explicitly (it then re-raises so the adapter still marks the job
  # failed). HandleExceptionJob is skipped to avoid an infinite notify loop.
  def notify_terminal_failure(exception) # @spec EXCEPTION-NOTIFY-003
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

  def with_perform_timeout(&block)
    timeout = self.class.perform_timeout&.to_i
    return yield if timeout.nil? || timeout <= 0

    Timeout.timeout(timeout, PerformTimeoutError, "#{self.class.name} exceeded perform_timeout of #{timeout}s", &block)
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
      ProjectHealthCheckJob,
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
