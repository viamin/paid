# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::Broadcaster do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)
      allow(Dashboard::CacheVersion).to receive(:bump).and_call_original
    end

    it "bumps the dashboard cache version and refreshes live stats" do
      described_class.call(account: account)

      expect(Dashboard::CacheVersion).to have_received(:bump).with(
        account,
        scope: Dashboard::CacheVersion::LISTS_SCOPE
      )
      expect(Dashboard::CacheVersion).to have_received(:bump).with(
        account,
        scope: Dashboard::CacheVersion::STATS_SCOPE
      )
      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "live-stats", partial: "dashboard/live_stats")
      )
    end

    it "does not use wildcard cache invalidation" do
      allow(Rails.cache).to receive(:delete_matched).and_call_original

      described_class.call(account: account)

      expect(Rails.cache).not_to have_received(:delete_matched).with("dashboard/stats/#{account.id}/*")
      expect(Rails.cache).not_to have_received(:delete_matched).with("dashboard/queue_preview/#{account.id}/*")
      expect(Rails.cache).not_to have_received(:delete_matched).with("dashboard/recent_activity/#{account.id}/*")
    end
  end
end
