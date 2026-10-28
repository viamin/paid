# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-014
RSpec.describe OpenrouterZdr::SyncJob do
  it "runs the endpoint eligibility refresh on the maintenance queue" do
    allow(OpenrouterZdr::Sync).to receive(:call)

    described_class.perform_now

    expect(described_class.new.queue_name).to eq("maintenance")
    expect(OpenrouterZdr::Sync).to have_received(:call)
  end
end
