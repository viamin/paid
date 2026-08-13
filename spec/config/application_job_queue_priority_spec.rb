# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob, :no_db do
  let(:expected_queue_assignments) do
    {
      default: %w[
        AgentRunCancellationJob
        AgentRunResourceProfileRefreshJob
        AnomalyDetectionJob
        AutoReleaseEvaluationJob
        DependabotAutoMergeJob
        DiagnoseErrorJob
        DispatchCircuitBreakerOutcomeJob
        FailureRecoveryDecisionJob
        GithubTokenValidationJob
        HandleExceptionJob
        HumanFeedbackCollectionJob
        ModelsSyncJob
        ProcessRunQueueJob
        ProjectHealthCheckJob
        QdrantCollectionCleanupJob
        RetryTimedOutIssueGoalJob
      ],
      maintenance: %w[
        AnalyzeIssueFollowupBackfillJob
        AccountHealthCheckSweepJob
        AutoPickEligibilitySweepJob
        AutoPickQueueBackfillJob
        AgentRunPatternDetectorJob
        AgentRunResourceJanitorJob
        AuditEventRetentionJob
        BillingPeriodManagementJob
        DependencyBackfillJob
        DispatchCircuitBreakerRecoveryJob
        DockerOrphanCleanupJob
        ClaudeAuthHealthCheckJob
        ClaudeCredentialKeepWarmJob
        CoordinationExperimentResolutionJob
        CoordinationPolicyEvolutionJob
        FreeModels::SyncJob
        GithubTokenHealthCheckJob
        KnowledgeAuditRetentionJob
        ModelHealthCheckJob
        OrphanBranchReaperJob
        PollWorkflowHealthCheckJob
        PoolReplenishmentJob
        PromptEvolutionJob
        QueueMonitorJob
        RemediationDecisionOutcomeJob
        RecoverMissingPullRequestLabelsJob
        RevertRemediationDecisionJob
        RunnerQuotaBalanceJob
        ScreenshotCleanupJob
        ServiceContainerReconciliationJob
        StaleRunDetectorJob
        StyleGuideEvolutionJob
        TemporalPatchGuardSweepJob
        WorktreeOrphanCleanupJob
      ],
      metrics: %w[
        AbTestAnalysisCheckJob
        AbTestAnalysisJob
        ContainerMetricsCollectionJob
        QualityMetricsCollectionJob
        ScheduledMutationSweepJob
        ServiceContainerMetricsCollectionJob
      ],
      knowledge: %w[
        EmbedChunksJob
        EnqueueKnowledgeCollectionJob
        KnowledgeEvolutionJob
        RunCollectorsJob
        StyleGuideCompressionJob
        StyleGuideExtractionJob
      ],
      low_priority: %w[
        DashboardBroadcastJob
        DelayedHumanFeedbackCollectionJob
        LiveDashboardBroadcastJob
        LlmOutputMetricFeedbackCollectionJob
      ]
    }
  end

  it "assigns each job to its expected queue" do
    expected_queue_assignments.each do |queue_name, job_classes|
      job_classes.each do |job_class_name|
        job = job_class_name.constantize.new
        expect(job.queue_name).to eq(queue_name.to_s),
          "Expected #{job_class_name} to be in #{queue_name} queue, " \
          "but found it in #{job.queue_name}"
      end
    end
  end

  it "assigns every job to a known queue" do
    all_expected = expected_queue_assignments.values.flatten
    job_files = Dir[Rails.root.join("app/jobs/*_job.rb")]
    job_classes = job_files.map { |f| File.basename(f, ".rb").camelize }

    # Exclude ApplicationJob which is the base class
    job_classes -= %w[ApplicationJob]

    unassigned = job_classes - all_expected
    expect(unassigned).to be_empty,
      "Jobs not assigned to any queue in the priority spec: #{unassigned.join(", ")}. " \
      "Add them to expected_queue_assignments."
  end
end
