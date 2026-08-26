# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScreenshotCleanupJob do
  describe "#perform" do
    context "when storage is configured" do
      let(:storage) { instance_double(Screenshots::Storage) }

      before do
        allow(Screenshots::Storage).to receive_messages(configured?: true, new: storage)
        allow(storage).to receive(:cleanup_old_screenshots).and_return(5)
      end

      it "cleans up old screenshots with default retention" do
        described_class.perform_now

        expect(storage).to have_received(:cleanup_old_screenshots).with(retention_days: 30)
      end

      it "accepts custom retention days" do
        described_class.perform_now(retention_days: 60)

        expect(storage).to have_received(:cleanup_old_screenshots).with(retention_days: 60)
      end

      it "logs the cleanup result" do
        allow(Rails.logger).to receive(:info)

        described_class.perform_now

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "screenshots.cleanup_completed",
            deleted_count: 5,
            retention_days: 30
          )
        )
      end
    end

    context "when storage is not configured" do
      before do
        allow(Screenshots::Storage).to receive(:configured?).and_return(false)
      end

      it "skips cleanup" do
        expect(Screenshots::Storage).not_to receive(:new)

        described_class.perform_now
      end
    end
  end

  describe "page load measurement retention" do
    let(:project) { create(:project) }
    let(:storage) { instance_double(Screenshots::Storage, cleanup_old_screenshots: 0) }

    before do
      allow(Screenshots::Storage).to receive_messages(configured?: true, new: storage)
    end

    # @spec PAGE-LOAD-LEDGER-004
    it "prunes measurements older than the screenshot retention period" do
      stale = create(:page_load_measurement, project: project, commit_sha: "old111", captured_at: 45.days.ago)
      fresh = create(:page_load_measurement, project: project, commit_sha: "new222", captured_at: 1.day.ago)

      described_class.perform_now

      expect(PageLoadMeasurement.where(id: stale.id)).to be_empty
      expect(PageLoadMeasurement.where(id: fresh.id)).to be_present
    end
  end
end
