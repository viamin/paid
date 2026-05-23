# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ReenqueueEligibleJob do
  include ActiveJob::TestHelper

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = original_adapter
  end

  describe ".schedule_no_runner_retry" do
    it "enqueues a short delayed retry with the next retry count" do
      freeze_time do
        expect {
          described_class.schedule_no_runner_retry(42, no_runner_retry_count: 0)
        }.to have_enqueued_job(described_class).with(42, no_runner_retry_count: 1).at(30.seconds.from_now)
      end
    end

    it "caps the no-runner backoff at one minute" do
      freeze_time do
        expect {
          described_class.schedule_no_runner_retry(42, no_runner_retry_count: 2)
        }.to have_enqueued_job(described_class).with(42, no_runner_retry_count: 3).at(1.minute.from_now)
      end
    end

    it "stops scheduling once the retry cap is reached" do
      expect {
        described_class.schedule_no_runner_retry(42, no_runner_retry_count: described_class::MAX_NO_RUNNER_RETRIES)
      }.not_to have_enqueued_job(described_class)
    end
  end

  describe "GoodJob concurrency" do
    it "deduplicates re-enqueue work per issue" do
      issue = build(:issue)
      config = described_class.good_job_concurrency_config

      expect(config[:enqueue_limit]).to eq(1)
      expect(described_class.new(issue.id).good_job_concurrency_key).to eq("reenqueue_eligible_issue_#{issue.id}")
    end
  end

  describe "#perform" do
    it "rechecks an eligible issue" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).to have_received(:call).with(
        issue,
        project: project,
        skip_project_gate: true,
        no_runner_retry_count: 0
      )
    end

    it "forwards the current no-runner retry count" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id, no_runner_retry_count: 2)

      expect(Issues::EnqueueEligible).to have_received(:call).with(
        issue,
        project: project,
        skip_project_gate: true,
        no_runner_retry_count: 2
      )
    end

    it "does nothing for missing issues" do
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(-1)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing for pull requests" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, :pull_request, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing for intentional waiting states" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "needs_input", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing when the auto-pick project gate defers work" do
      project = create(:project, auto_pick_enabled: true, quality_paused_at: Time.current)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "logs and swallows enqueue errors" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call).and_raise(StandardError, "transient failure")
      allow(Rails.logger).to receive(:error)

      expect { described_class.perform_now(issue.id, no_runner_retry_count: 2) }.not_to raise_error
      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "enqueue_eligible.issue_state_change_failed",
          issue_id: issue.id,
          no_runner_retry_count: 2,
          error: "transient failure"
        )
      )
    end
  end
end
