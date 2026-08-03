# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-008
RSpec.describe FreeModels::SyncJob do
  describe "#perform" do
    it "delegates to the sync service" do
      allow(FreeModels::Sync).to receive(:call)

      described_class.perform_now

      expect(FreeModels::Sync).to have_received(:call)
    end
  end

  it "runs on the maintenance queue" do
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
