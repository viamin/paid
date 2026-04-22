# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    Database::QueryMonitor.instrument("job", job_class: job.class.name) do
      block.call
    end
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  around_perform :with_tenant_context

  private

  def with_tenant_context(&block)
    account = TenantContext.with_system_access { tenant_account }
    return TenantContext.with(account, &block) if account

    TenantContext.with_system_access(&block)
  ensure
    TenantContext.clear!
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
      EmbedChunksJob,
      EnqueueKnowledgeCollectionJob,
      PoolReplenishmentJob,
      RunCollectorsJob,
      StyleGuideExtractionJob
    ].any? { |job_class| is_a?(job_class) }
  end

  def agent_run_id_first?
    [
      AgentRunResourceJanitorJob,
      AnomalyDetectionJob,
      ContainerMetricsCollectionJob,
      DiagnoseErrorJob,
      HumanFeedbackCollectionJob,
      QualityMetricsCollectionJob,
      RetryTimedOutIssueGoalJob
    ].any? { |job_class| is_a?(job_class) }
  end
end
