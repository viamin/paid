# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Worker pool load behavior", type: :model do
  describe "GoodJob queue prioritization" do
    {
      ProcessRunQueueJob => "default",
      DiagnoseErrorJob => "default",
      HumanFeedbackCollectionJob => "default",
      GithubTokenValidationJob => "default",
      DockerOrphanCleanupJob => "maintenance",
      StaleRunDetectorJob => "maintenance",
      PollWorkflowHealthCheckJob => "maintenance",
      WorktreeOrphanCleanupJob => "maintenance",
      AgentRunResourceJanitorJob => "maintenance",
      ServiceContainerReconciliationJob => "maintenance",
      RecoverMissingPullRequestLabelsJob => "maintenance",
      KnowledgeAuditRetentionJob => "maintenance",
      ContainerMetricsCollectionJob => "metrics",
      ServiceContainerMetricsCollectionJob => "metrics",
      QualityMetricsCollectionJob => "metrics",
      AbTestAnalysisCheckJob => "metrics",
      AbTestAnalysisJob => "metrics",
      EmbedChunksJob => "knowledge",
      StyleGuideExtractionJob => "knowledge",
      StyleGuideCompressionJob => "knowledge",
      DashboardBroadcastJob => "low_priority",
      LiveDashboardBroadcastJob => "low_priority",
      DelayedHumanFeedbackCollectionJob => "low_priority"
    }.each do |job_class, expected_queue|
      it "assigns #{job_class} to the #{expected_queue} queue" do
        expect(job_class.new.queue_name).to eq(expected_queue)
      end
    end

    it "processes higher-priority queues before lower-priority ones" do
      queue_order = Rails.application.config.good_job.queues
        .split(";")
        .map { |entry| entry.split(":").first }

      expect(queue_order.index("default")).to be < queue_order.index("maintenance")
      expect(queue_order.index("maintenance")).to be < queue_order.index("metrics")
      expect(queue_order.index("metrics")).to be < queue_order.index("knowledge")
      expect(queue_order.index("knowledge")).to be < queue_order.index("low_priority")
    end

    it "allocates per-queue thread caps that sum to max_threads" do
      queue_string = Rails.application.config.good_job.queues
      max_threads = Rails.application.config.good_job.max_threads

      thread_sum = queue_string.split(";").sum do |entry|
        _name, threads = entry.split(":")
        threads.to_i
      end

      expect(thread_sum).to be <= max_threads,
        "Per-queue thread caps (#{thread_sum}) should not exceed max_threads (#{max_threads})"
    end
  end

  describe "database connection pool sizing" do
    it "has sufficient pool size for web threads plus job threads" do
      db_pool = ActiveRecord::Base.connection_pool.size
      good_job_threads = Rails.application.config.good_job.max_threads
      rails_threads = ENV.fetch("RAILS_MAX_THREADS", 3).to_i

      # DB pool must accommodate both web request threads and job worker threads
      expect(db_pool).to be >= (rails_threads + good_job_threads),
        "DB_POOL (#{db_pool}) should be >= RAILS_MAX_THREADS (#{rails_threads}) + " \
        "GOOD_JOB_MAX_THREADS (#{good_job_threads})"
    end
  end

  describe "GoodJob concurrency controls" do
    # Jobs with global singleton concurrency (only one instance system-wide)
    [
      DockerOrphanCleanupJob,
      RecoverMissingPullRequestLabelsJob,
      ServiceContainerReconciliationJob,
      StaleRunDetectorJob,
      PollWorkflowHealthCheckJob,
      ProcessRunQueueJob
    ].each do |job_class|
      it "limits #{job_class} to one concurrent execution globally" do
        config = job_class.good_job_concurrency_config
        expect(config[:total_limit]).to eq(1),
          "#{job_class} should have total_limit: 1"
        expect(config[:enqueue_limit]).to eq(1),
          "#{job_class} should have enqueue_limit: 1"
      end
    end

    # Jobs with per-resource concurrency (keyed by argument)
    [
      ContainerMetricsCollectionJob,
      ServiceContainerMetricsCollectionJob,
      RunCollectorsJob,
      DashboardBroadcastJob,
      LiveDashboardBroadcastJob
    ].each do |job_class|
      it "limits #{job_class} to one concurrent execution per resource" do
        config = job_class.good_job_concurrency_config
        expect(config[:total_limit]).to eq(1),
          "#{job_class} should have total_limit: 1"
        expect(config[:key]).to be_a(Proc),
          "#{job_class} should have a dynamic concurrency key"
      end
    end
  end

  describe "Temporal worker configuration" do
    it "has sensible default slot ratios" do
      workflow_slots = ENV.fetch("TEMPORAL_WORKFLOW_SLOTS", "20").to_i
      activity_slots = ENV.fetch("TEMPORAL_ACTIVITY_SLOTS", "4").to_i

      # Workflow slots should exceed activity slots since workflows are lightweight
      # (in-memory replay) while activities are heavy (Docker/LLM I/O)
      expect(workflow_slots).to be >= activity_slots,
        "Workflow slots (#{workflow_slots}) should be >= activity slots (#{activity_slots})"

      # Activity slots should be at least 2 for basic concurrency
      expect(activity_slots).to be >= 2,
        "Activity slots (#{activity_slots}) should be >= 2 for concurrent execution"
    end

    it "has DB pool sized for activity concurrency" do
      db_pool = ActiveRecord::Base.connection_pool.size
      activity_slots = ENV.fetch("TEMPORAL_ACTIVITY_SLOTS", "4").to_i
      local_activity_slots = ENV.fetch("TEMPORAL_LOCAL_ACTIVITY_SLOTS", activity_slots.to_s).to_i
      min_required = activity_slots + local_activity_slots + 2

      expect(db_pool).to be >= min_required,
        "DB_POOL (#{db_pool}) should be >= activity_slots (#{activity_slots}) + " \
        "local_activity_slots (#{local_activity_slots}) + 2 = #{min_required}"
    end
  end

  describe "shutdown behavior" do
    it "configures GoodJob shutdown timeout less than container stop timeout" do
      shutdown_timeout = Rails.application.config.good_job.shutdown_timeout
      # Docker default stop timeout is 30s; GoodJob should finish before that
      expect(shutdown_timeout).to be < 30
    end

    it "configures Temporal graceful shutdown to allow activity completion" do
      graceful_shutdown = ENV.fetch("TEMPORAL_GRACEFUL_SHUTDOWN_PERIOD", "30").to_i
      expect(graceful_shutdown).to be >= 10
      expect(graceful_shutdown).to be <= 120
    end
  end
end
