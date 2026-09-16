# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::TokenLimitErrorMessage do
  # @spec CHAT-API-014
  describe ".build" do
    context "with a session limit" do
      it "explains the session limit was reached with usage and guidance" do
        result = described_class.build(limit_type: "session", limit: 5_000_000, used: 5_193_598)

        expect(result.content).to include("Session chat token limit reached")
        expect(result.content).to include("Used 5,193,598 of 5,000,000 tokens allowed")
        expect(result.content).to include("Start a new chat session")
        expect(result.content).to include("ask an administrator to increase")
      end

      it "returns metadata identifying the rejection" do
        result = described_class.build(limit_type: "session", limit: 100, used: 110)

        expect(result.metadata).to eq(
          "token_limit_error" => true,
          "limit_type" => "session",
          "limit" => 100,
          "used_tokens" => 110
        )
      end
    end

    context "with a monthly limit" do
      it "explains that a new session will not help" do
        result = described_class.build(limit_type: "monthly", limit: 100, used: 110)

        expect(result.content).to include("Monthly chat token limit reached")
        expect(result.content).to include("Starting a new chat session will not help")
        expect(result.content).to include("ask an administrator to increase the account's monthly")
      end
    end
  end
end
