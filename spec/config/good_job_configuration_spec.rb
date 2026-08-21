# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoodJob, :no_db do # @spec RAILS-CONTROL-PLANE-003
  around do |example|
    original_env = ENV.to_h.slice(
      "GOOD_JOB_EXECUTION_MODE",
      "GOOD_JOB_BOOTSTRAP_ON_START",
      "GOOD_JOB_MAX_THREADS",
      "GOOD_JOB_POLL_INTERVAL",
      "GOOD_JOB_SHUTDOWN_TIMEOUT",
      "GOOD_JOB_QUEUES"
    )

    %w[
      GOOD_JOB_EXECUTION_MODE
      GOOD_JOB_BOOTSTRAP_ON_START
      GOOD_JOB_MAX_THREADS
      GOOD_JOB_POLL_INTERVAL
      GOOD_JOB_SHUTDOWN_TIMEOUT
      GOOD_JOB_QUEUES
    ].each { |key| ENV.delete(key) }

    example.run
  ensure
    %w[
      GOOD_JOB_EXECUTION_MODE
      GOOD_JOB_BOOTSTRAP_ON_START
      GOOD_JOB_MAX_THREADS
      GOOD_JOB_POLL_INTERVAL
      GOOD_JOB_SHUTDOWN_TIMEOUT
      GOOD_JOB_QUEUES
    ].each { |key| ENV.delete(key) }
    original_env.each { |key, value| ENV[key] = value }
  end

  describe "execution mode" do
    it "defaults to async_server" do
      expect(Paid::GoodJobConfig.execution_mode).to eq(:async_server)
    end
  end

  describe "startup bootstrap" do
    it "runs for the Rails server process" do
      expect(Paid::GoodJobConfig.bootstrap_startup_jobs?(server_process: true)).to be(true)
    end

    it "does not run for non-server async_server processes" do
      ENV["GOOD_JOB_EXECUTION_MODE"] = "async_server"

      expect(Paid::GoodJobConfig.bootstrap_startup_jobs?(server_process: false)).to be(false)
    end

    it "runs for the dedicated external job role when explicitly enabled" do
      ENV["GOOD_JOB_EXECUTION_MODE"] = "external"
      ENV["GOOD_JOB_BOOTSTRAP_ON_START"] = "true"

      expect(Paid::GoodJobConfig.bootstrap_startup_jobs?(server_process: false)).to be(true)
    end

    it "does not run for unrelated external processes" do
      ENV["GOOD_JOB_EXECUTION_MODE"] = "external"

      expect(Paid::GoodJobConfig.bootstrap_startup_jobs?(server_process: false)).to be(false)
    end
  end

  describe "max_threads" do
    it "defaults to 11" do
      expect(Paid::GoodJobConfig.max_threads).to eq(11)
    end
  end

  describe "poll_interval" do
    it "defaults to 3 seconds" do
      expect(Paid::GoodJobConfig.poll_interval).to eq(3)
    end
  end

  describe "shutdown_timeout" do
    it "defaults to 25 seconds" do
      expect(Paid::GoodJobConfig.shutdown_timeout).to eq(25)
    end
  end

  describe "queue configuration" do
    it "defines per-queue thread caps with default first" do
      queues = Paid::GoodJobConfig.queues
      queue_entries = queues.split(";")

      expect(queue_entries.first).to start_with("default:")
      expect(queue_entries.map { |e| e.split(":").first }).to eq(
        %w[default maintenance metrics knowledge low_priority]
      )
    end

    it "does not allocate more per-queue threads than max_threads" do
      queues = Paid::GoodJobConfig.queues
      total_threads = queues.split(";").sum { |e| e.split(":").last.to_i }
      max_threads = Paid::GoodJobConfig.max_threads

      expect(total_threads).to be <= max_threads
    end
  end

  describe "cron schedule" do
    let(:cron) { Rails.application.config.good_job.cron }
    let(:staggered_offsets) do
      {
        process_run_queue: "*/5 * * * *",
        poll_workflow_health_check: "1-59/5 * * * *",
        service_container_reconciliation: "1-59/5 * * * *",
        dispatch_circuit_breaker_recovery: "1-59/5 * * * *",
        stale_run_detector: "2-59/5 * * * *",
        queue_monitor: "2-59/5 * * * *",
        docker_orphan_cleanup: "3-59/5 * * * *",
        notifications_check_runner_quotas: "3-59/5 * * * *",
        container_pool_replenishment: "4-59/5 * * * *",
        chat_idle_reaper: "4-59/5 * * * *",
        execution_resource_reconciliation: "5-59/5 * * * *",
        auto_pick_eligibility_sweep: "7-59/15 * * * *",
        runner_quota_balance: "9-59/15 * * * *",
        agent_run_pattern_detector: "11-59/15 * * * *",
        remediation_decision_outcomes: "13-59/15 * * * *"
      }
    end

    it "defines expected cron jobs" do # @spec TEMPORAL-ORCHESTRATION-003
      expected_jobs = %i[
        worktree_cleanup poll_workflow_health_check stale_run_detector
        docker_orphan_cleanup recover_missing_pull_request_labels models_sync
        free_models_sync
        ab_test_analysis process_run_queue auto_pick_queue_backfill
        auto_pick_eligibility_sweep service_container_reconciliation
        execution_resource_reconciliation screenshot_cleanup
        knowledge_audit_retention delayed_human_feedback notifications_check_runner_quotas
        runner_quota_balance account_health_check_sweep
        claude_auth_health_check style_guide_evolution
        agent_run_pattern_detector billing_period_management
      ]

      expected_jobs.each do |job_key|
        expect(cron).to have_key(job_key), "Expected cron job #{job_key} to be defined"
      end
    end

    it "staggers frequent maintenance jobs across minute boundaries" do
      aggregate_failures do
        staggered_offsets.each do |job_key, schedule|
          expect(cron.fetch(job_key)).to include(cron: schedule)
        end
      end
    end
  end
end
