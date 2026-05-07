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
end
