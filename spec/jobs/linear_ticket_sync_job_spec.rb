# frozen_string_literal: true

require "rails_helper"

RSpec.describe LinearTicketSyncJob do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:token) { create(:linear_token, account:) }
  let!(:configuration) { create(:tracker_configuration, :linear, configurable: account, linear_token: token) }

  around do |example|
    original_cache = Rails.cache
    test_cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = test_cache
    Rails.cache.clear
    example.run
  ensure
    test_cache.clear
    Rails.cache = original_cache
  end

  it "synchronizes only due accounts with an enabled project" do
    # @spec UNIFIED-WORK-ITEMS-002 UNIFIED-WORK-ITEMS-009
    FeatureFlags.enable!(:unified_work_items, project:)
    request = stub_request(:post, "https://api.linear.app/graphql").to_return(
      status: 200, body: JSON.generate(data: { issues: { nodes: [],
        pageInfo: { hasNextPage: false, endCursor: nil } } })
    )

    described_class.perform_now
    expect(configuration.reload.connection_health).to eq("healthy")
    expect(request).to have_been_requested.once

    described_class.perform_now
    expect(request).to have_been_requested.once
  end

  it "does not request Linear for an account with no enabled project" do
    # @spec UNIFIED-WORK-ITEMS-009
    described_class.perform_now

    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
    expect(configuration.reload.last_synced_at).to be_nil
  end

  it "caches the missing rollout project until the cache expires" do
    # @spec UNIFIED-WORK-ITEMS-009
    request = stub_request(:post, "https://api.linear.app/graphql").to_return(
      status: 200, body: JSON.generate(data: { issues: { nodes: [],
        pageInfo: { hasNextPage: false, endCursor: nil } } })
    )

    described_class.perform_now
    FeatureFlags.enable!(:unified_work_items, project:)
    described_class.perform_now
    expect(request).not_to have_been_requested

    travel 6.minutes do
      described_class.perform_now
    end
    expect(request).to have_been_requested.once
  end
end
