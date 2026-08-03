# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Cache do
  let(:project) { create(:project) }
  let(:result) do
    HealthChecks::Result.new(
      findings: [
        HealthChecks::Finding.new(code: :test, scope: :project, severity: :info, title: "test")
      ],
      checked_at: Time.current,
      duration_ms: 42
    )
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    example.run
  ensure
    Rails.cache = original_cache
  end

  describe ".read and .write" do
    it "writes and reads a Result for a subject" do
      described_class.write(project, result)

      cached = described_class.read(project)
      expect(cached).to eq(result)
    end

    it "returns nil for an uncached subject" do
      expect(described_class.read(project)).to be_nil
    end

    it "keys entries by subject type and id" do
      described_class.write(project, result)

      expect(Rails.cache.read("project_health/project/#{project.id}")).to eq(result)
    end
  end

  describe ".clear" do
    it "removes the cached entry" do
      described_class.write(project, result)
      expect(described_class.read(project)).to be_present

      described_class.clear(project)

      expect(described_class.read(project)).to be_nil
    end

    it "supports the delete alias" do
      described_class.write(project, result)

      described_class.delete(project)

      expect(described_class.read(project)).to be_nil
    end
  end

  describe "TTL" do
    it "sets an expires_in on the cache entry" do
      described_class.write(project, result, ttl: 5.seconds)

      travel_to(4.seconds.from_now) do
        expect(described_class.read(project)).to be_present
      end
    end

    it "expires the cache after the TTL" do
      described_class.write(project, result, ttl: 1.second)

      travel_to(2.seconds.from_now) do
        expect(described_class.read(project)).to be_nil
      end
    end
  end

  describe "cache key partitioning" do
    it "generates different keys for different subject types" do
      user = create(:user)

      described_class.write(project, result)
      described_class.write(user, result)

      expect(described_class.read(project)).to be_present
      expect(described_class.read(user)).to be_present
    end
  end
end
