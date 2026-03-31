# frozen_string_literal: true

require "rails_helper"

RSpec.describe DelayedHumanFeedbackCollectionJob do
  describe "#perform" do
    it "enqueues feedback collection for recently completed runs" do
      recent_run = create(:agent_run, :completed)
      recent_run.update_columns(completed_at: 1.day.ago, updated_at: 1.day.ago)

      expect {
        described_class.new.perform
      }.to have_enqueued_job(HumanFeedbackCollectionJob).with(recent_run.id)
    end

    it "enqueues runs with nil completed_at but recent updated_at" do
      run_without_completed = create(:agent_run, :completed)
      run_without_completed.update_columns(completed_at: nil, updated_at: 1.day.ago)

      expect {
        described_class.new.perform
      }.to have_enqueued_job(HumanFeedbackCollectionJob).with(run_without_completed.id)
    end

    it "skips runs completed outside the lookback window" do
      old_run = create(:agent_run, :completed)
      old_run.update_columns(completed_at: 8.days.ago, updated_at: 8.days.ago)

      expect {
        described_class.new.perform
      }.not_to have_enqueued_job(HumanFeedbackCollectionJob)
    end

    it "skips non-completed runs" do
      create(:agent_run, :running)

      expect {
        described_class.new.perform
      }.not_to have_enqueued_job(HumanFeedbackCollectionJob)
    end

    it "skips runs whose human metric was polled within the sweep interval" do
      recent_run = create(:agent_run, :completed)
      recent_run.update_columns(completed_at: 1.day.ago, updated_at: 1.day.ago)
      recent_run.quality_metrics.create!(
        metric_type: "human",
        scores: { "pr_merged" => 1.0 },
        composite_score: 1.0,
        metadata: { "last_polled_at" => 2.hours.ago.iso8601 }
      )

      expect {
        described_class.new.perform
      }.not_to have_enqueued_job(HumanFeedbackCollectionJob)
    end

    it "includes runs whose human metric was polled longer ago than the sweep interval" do
      stale_run = create(:agent_run, :completed)
      stale_run.update_columns(completed_at: 1.day.ago, updated_at: 1.day.ago)
      stale_run.quality_metrics.create!(
        metric_type: "human",
        scores: { "pr_merged" => 1.0 },
        composite_score: 1.0,
        metadata: { "last_polled_at" => 5.hours.ago.iso8601 }
      )

      expect {
        described_class.new.perform
      }.to have_enqueued_job(HumanFeedbackCollectionJob).with(stale_run.id)
    end

    it "includes runs when last_polled_at is stale despite recent updated_at from webhooks" do
      run = create(:agent_run, :completed)
      run.update_columns(completed_at: 1.day.ago, updated_at: 1.day.ago)
      # Metric has recent updated_at (from a webhook comment) but stale last_polled_at.
      # The sweep should use last_polled_at, not updated_at, to decide.
      run.quality_metrics.create!(
        metric_type: "human",
        scores: { "pr_merged" => 1.0 },
        composite_score: 1.0,
        metadata: { "webhook_comment_count" => 3, "last_polled_at" => 5.hours.ago.iso8601 },
        updated_at: 1.hour.ago
      )

      expect {
        described_class.new.perform
      }.to have_enqueued_job(HumanFeedbackCollectionJob).with(run.id)
    end

    it "falls back to updated_at for metrics without last_polled_at" do
      run = create(:agent_run, :completed)
      run.update_columns(completed_at: 1.day.ago, updated_at: 1.day.ago)
      run.quality_metrics.create!(
        metric_type: "human",
        scores: { "pr_merged" => 1.0 },
        composite_score: 1.0,
        metadata: {},
        updated_at: 2.hours.ago
      )

      expect {
        described_class.new.perform
      }.not_to have_enqueued_job(HumanFeedbackCollectionJob)
    end
  end
end
