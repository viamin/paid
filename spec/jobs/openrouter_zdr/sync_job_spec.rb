# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::SyncJob do
  it "delegates to the ZDR sync service on the maintenance queue" do # @spec OPENROUTER-ZDR-CATALOG-001
    allow(OpenrouterZdr::Sync).to receive(:call)

    described_class.perform_now

    expect(OpenrouterZdr::Sync).to have_received(:call)
    expect(described_class.new.queue_name).to eq("maintenance")
  end
end
