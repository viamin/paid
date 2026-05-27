# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::ProviderHealth, :no_db do
  subject(:service) { described_class.allocate }

  let(:runner_status) do
    Dashboard::RunnerHealth::RunnerStatus.new(
      runner: "Claude",
      owner_name: "Owner",
      owner_email: "owner@example.com",
      auth_type: "Subscription",
      status: :available,
      status_label: "Available",
      available: true,
      failure_count: 0,
      attempt_count: 4,
      rate_limited_until: nil
    )
  end

  let(:payload) do
    service.send(:legacy_provider_payload,
      runners: [ runner_status ],
      total: 1,
      available: 1,
      rate_limited: 0,
      circuit_open: 0,
      recovering: 0,
      healthy: true
    )
  end

  it "keeps the legacy provider payload shape available" do
    expect(payload[:providers].first.provider).to eq("Claude")
    expect(payload[:providers].first.owner_email).to eq("owner@example.com")
    expect(payload[:providers].first.status).to eq(:available)
    expect(payload[:providers].first.attempt_count).to eq(4)
    expect(payload[:runners].first.runner).to eq("Claude")
  end
end
