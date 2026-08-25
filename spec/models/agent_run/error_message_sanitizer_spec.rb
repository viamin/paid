# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun::ErrorMessageSanitizer do
  describe ".call" do
    it "returns nil for blank input" do
      expect(described_class.call(text: nil)).to be_nil
      expect(described_class.call(text: "")).to be_nil
    end

    it "passes through plain message text unchanged" do
      expect(described_class.call(text: "Runner exited 1")).to eq("Runner exited 1")
    end

    it "redacts known secret shapes" do # @spec CHAT-API-011
      message = "auth failed for ghp_#{"a" * 36} at github.com"

      result = described_class.call(text: message)

      expect(result).to include("[REDACTED:github_token]")
      expect(result).not_to include("ghp_")
    end

    it "normalizes invalid UTF-8 and strips NUL bytes" do
      expect(described_class.call(text: "boom\xFF".b)).to eq("boom\uFFFD")
      expect(described_class.call(text: "a\x00b")).to eq("ab")
    end

    it "truncates to the shared cap after redaction" do
      result = described_class.call(text: "x" * 600)

      expect(result.length).to eq(AgentRun::MAX_RUNNER_ATTEMPT_ERROR_MESSAGE_LENGTH)
    end
  end
end
