# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-013
RSpec.describe OpenrouterZdr::SyncJob do
  it "delegates to the ZDR catalog sync on the maintenance queue" do
    allow(OpenrouterZdr::Sync).to receive(:call)

    described_class.perform_now

    expect(OpenrouterZdr::Sync).to have_received(:call)
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
