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
  end
end
