# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::CacheMetrics do
  describe ".subscribe!" do
    it "subscribes to all cache events" do
      described_class.subscribe!

      expect(Github::CacheMetrics::EVENTS).to contain_exactly(
        "github_cache.hit",
        "github_cache.miss",
        "github_cache.invalidate"
      )
    end

    it "logs events via Rails.logger" do
      described_class.subscribe!
      allow(Rails.logger).to receive(:info)

      ActiveSupport::Notifications.instrument("github_cache.hit", cache_key: "test/key") do
        # block required for duration tracking
      end

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "github_cache.hit",
          component: "github_cache"
        )
      ).at_least(:once)
    end
  end
end
