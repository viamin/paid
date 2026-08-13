# frozen_string_literal: true

require "rails_helper"
require "redis"

# Locks the contract that `Config::ProductionValidator` depends on: a missing
# `REDIS_URL` must not raise `KeyError` from `Coordination.redis`, otherwise the
# validator's "warning only" treatment of a localhost/blank REDIS_URL would
# silently defer the failure to the first interactive-login call instead of
# surfacing it at boot.
RSpec.describe ClaudeLoginSessions::Coordination do
  describe ".redis" do
    around do |example|
      original = ENV["REDIS_URL"]
      example.run
    ensure
      if original
        ENV["REDIS_URL"] = original
      else
        ENV.delete("REDIS_URL")
      end
    end

    before { described_class.instance_variable_set(:@redis, nil) }
    after { described_class.instance_variable_set(:@redis, nil) }

    it "connects to REDIS_URL when it is set" do
      ENV["REDIS_URL"] = "redis://example.test:6379/5"
      fake = instance_double(Redis)
      allow(Redis).to receive(:new).with(url: "redis://example.test:6379/5").and_return(fake)

      expect(described_class.redis).to eq(fake)
    end

    it "falls back to a localhost default when REDIS_URL is unset" do
      ENV.delete("REDIS_URL")
      fake = instance_double(Redis)
      allow(Redis).to receive(:new).with(url: described_class::DEFAULT_REDIS_URL).and_return(fake)

      expect(described_class.redis).to eq(fake)
    end
  end
end
