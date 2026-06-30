# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::Cooldown do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-06-30 12:00:00 UTC") }

  describe ".lock" do
    it "stores the decision and freezes reads for the cooldown window" do
      described_class.lock("memory_limit:paid_agents", value: 4096, cooldown: 5.minutes, now: now, cache: cache)

      snapshot = described_class.read("memory_limit:paid_agents", now: now, cache: cache)

      expect(snapshot[:value]).to eq(4096)
      expect(snapshot[:frozen_until]).to be_within(1.second).of(now + 5.minutes)
      expect(described_class.frozen?("memory_limit:paid_agents", now: now, cache: cache)).to be(true)
    end

    it "expires the freeze after the cooldown elapses" do
      described_class.lock("memory_limit:paid_agents", value: 2048, cooldown: 1.minute, now: now, cache: cache)

      expect(described_class.read("memory_limit:paid_agents", now: now + 2.minutes, cache: cache)).to be_nil
    end

    it "returns the previous decision so callers can detect changes" do
      previous = nil
      previous = described_class.lock("max_concurrent:user_42", value: 4, cooldown: 5.minutes, now: now, cache: cache)
      previous = described_class.lock("max_concurrent:user_42", value: 5, cooldown: 5.minutes, now: now, cache: cache)

      expect(previous[:value]).to eq(4)
    end

    it "does not flip the decision back when held in cooldown" do
      described_class.lock("max_concurrent:user_42", value: 4, cooldown: 5.minutes, now: now, cache: cache)

      expect(described_class.frozen?("max_concurrent:user_42", now: now + 2.minutes, cache: cache)).to be(true)
      expect(described_class.read("max_concurrent:user_42", now: now + 2.minutes, cache: cache)[:value]).to eq(4)
    end
  end

  describe ".reset!" do
    it "removes the cooldown immediately" do
      described_class.lock("memory_limit:paid_agents", value: 4096, cooldown: 5.minutes, now: now, cache: cache)
      described_class.reset!("memory_limit:paid_agents", cache: cache)

      expect(described_class.frozen?("memory_limit:paid_agents", now: now, cache: cache)).to be(false)
    end
  end

  describe "anti-oscillation pattern" do
    it "supports a memory-limit raising pattern that holds until evidence is fresh" do
      # Initial conservative decision
      described_class.lock("memory_limit:project_42", value: 2048, cooldown: 5.minutes, now: now, cache: cache)

      # Two minutes later, an OOM event happens — but cooldown is still active
      later = now + 2.minutes
      previous = described_class.lock("memory_limit:project_42", value: 4096, cooldown: 5.minutes, now: later, cache: cache)

      # The previous decision is still remembered; the policy should treat
      # the lock as a signal that raising did not happen yet.
      expect(previous[:value]).to eq(2048)

      # Five minutes pass; the cooldown expires, allowing a new decision
      released = now + 6.minutes
      described_class.lock("memory_limit:project_42", value: 4096, cooldown: 5.minutes, now: released, cache: cache)

      expect(described_class.read("memory_limit:project_42", now: released, cache: cache)[:value]).to eq(4096)
    end
  end
end
