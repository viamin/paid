# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ErrorMessage do
  describe ".for" do
    it "returns the raw message for a rate limit error without a reset time" do
      error = AgentHarness::RateLimitError.new("API rate limit exceeded")

      expect(described_class.for(error)).to eq("API rate limit exceeded")
    end

    it "appends the reset time for a rate limit error that exposes one" do
      reset_time = Time.utc(2026, 6, 29, 18, 30)
      error = AgentHarness::RateLimitError.new("API rate limit exceeded", reset_time: reset_time)

      expect(described_class.for(error))
        .to eq("API rate limit exceeded (resets at #{I18n.l(reset_time, format: :long)})")
    end

    it "does not raise when reset_time is not a Date/Time value" do
      error = AgentHarness::RateLimitError.new("API rate limit exceeded", reset_time: "soon")

      expect { described_class.for(error) }.not_to raise_error
      expect(described_class.for(error)).to eq("API rate limit exceeded")
    end

    it "falls back to a generic message for a blank provider error" do
      error = AgentHarness::Error.new("")

      expect(described_class.for(error)).to eq("The selected chat runner could not complete the request")
    end

    it "returns the provider error message when present" do
      error = AgentHarness::Error.new("upstream exploded")

      expect(described_class.for(error)).to eq("upstream exploded")
    end
  end
end
