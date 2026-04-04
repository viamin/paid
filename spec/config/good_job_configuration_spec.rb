# frozen_string_literal: true

require "rails_helper"

RSpec.describe GoodJob do
  describe "execution mode" do
    it "defaults to async_server" do
      expect(Rails.application.config.good_job.execution_mode).to eq(:async_server)
    end
  end

  describe "max_threads" do
    it "defaults to 10" do
      expect(Rails.application.config.good_job.max_threads).to eq(10)
    end
  end

  describe "poll_interval" do
    it "defaults to 3 seconds" do
      expect(Rails.application.config.good_job.poll_interval).to eq(3)
    end
  end

  describe "shutdown_timeout" do
    it "defaults to 25 seconds" do
      expect(Rails.application.config.good_job.shutdown_timeout).to eq(25)
    end
  end

  describe "queue configuration" do
    it "defines per-queue thread caps with default first" do
      queues = Rails.application.config.good_job.queues
      queue_entries = queues.split(";")

      expect(queue_entries.first).to start_with("default:")
      expect(queue_entries.map { |e| e.split(":").first }).to eq(
        %w[default maintenance metrics knowledge low_priority]
      )
    end

    it "allocates threads that sum to max_threads" do
      queues = Rails.application.config.good_job.queues
      total_threads = queues.split(";").sum { |e| e.split(":").last.to_i }
      max_threads = Rails.application.config.good_job.max_threads

      expect(total_threads).to eq(max_threads)
    end
  end

  describe "cron schedule" do
    let(:cron) { Rails.application.config.good_job.cron }

    it "defines expected cron jobs" do
      expected_jobs = %i[
        worktree_cleanup poll_workflow_health_check stale_run_detector
        docker_orphan_cleanup recover_missing_pull_request_labels models_sync
        ab_test_analysis process_run_queue service_container_reconciliation
        knowledge_audit_retention delayed_human_feedback
      ]

      expected_jobs.each do |job_key|
        expect(cron).to have_key(job_key), "Expected cron job #{job_key} to be defined"
      end
    end
  end
end
