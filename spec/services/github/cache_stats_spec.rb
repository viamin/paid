# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::CacheStats do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    described_class.reset!
    example.run
  ensure
    Rails.cache = original_cache
  end

  describe ".snapshot" do
    it "returns zero stats when no events recorded" do
      stats = described_class.snapshot

      expect(stats[:hits]).to eq(0)
      expect(stats[:misses]).to eq(0)
      expect(stats[:invalidations]).to eq(0)
      expect(stats[:total_requests]).to eq(0)
      expect(stats[:hit_rate]).to eq(0.0)
    end

    it "tracks hits and misses" do
      3.times { described_class.record_hit }
      1.times { described_class.record_miss }

      stats = described_class.snapshot

      expect(stats[:hits]).to eq(3)
      expect(stats[:misses]).to eq(1)
      expect(stats[:total_requests]).to eq(4)
      expect(stats[:hit_rate]).to eq(0.75)
      expect(stats[:miss_rate]).to eq(0.25)
    end

    it "tracks invalidations separately" do
      described_class.record_invalidation

      stats = described_class.snapshot

      expect(stats[:invalidations]).to eq(1)
      expect(stats[:total_requests]).to eq(0)
    end
  end

  describe ".subscribe!" do
    it "returns subscriber objects" do
      subscribers = described_class.subscribe!

      expect(subscribers).to all(be_present)
    ensure
      subscribers&.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    end
  end

  describe ".reset!" do
    it "clears all counters" do
      described_class.record_hit
      described_class.record_miss
      described_class.reset!

      stats = described_class.snapshot
      expect(stats[:hits]).to eq(0)
      expect(stats[:misses]).to eq(0)
    end
  end

  describe ".record_hit" do
    it "initializes a missing counter and increments atomically" do
      described_class.record_hit
      described_class.record_hit

      expect(described_class.snapshot[:hits]).to eq(2)
    end
  end
end
