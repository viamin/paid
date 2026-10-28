# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::SyncJob do
  it "delegates the daily refresh to the ZDR sync service" do # @spec FREE-MODEL-SYNC-011
    allow(OpenrouterZdr::Sync).to receive(:call)

    described_class.perform_now

    expect(OpenrouterZdr::Sync).to have_received(:call)
  end
end
