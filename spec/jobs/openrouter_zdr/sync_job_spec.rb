# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-009
RSpec.describe OpenrouterZdr::SyncJob do
  it "runs on the maintenance queue and delegates to the catalog sync" do
    allow(OpenrouterZdr::Sync).to receive(:call)

    described_class.perform_now

    expect(described_class.new.queue_name).to eq("maintenance")
    expect(OpenrouterZdr::Sync).to have_received(:call)
  end
end
