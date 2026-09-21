# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RateLimitPauseMessage do
  # @spec CHAT-API-017
  describe ".build" do
    context "when auto-resume is enabled" do
      it "explains the pause and that the message will resend automatically" do
        reset_at = Time.zone.parse("2026-01-01 12:00:00")

        result = described_class.build(reset_at: reset_at, auto_resume: true)

        expect(result.content).to include("Chat paused: the runner hit a rate limit")
        expect(result.content).to include(I18n.l(reset_at, format: :long))
        expect(result.content).to include("will be resent automatically")
      end

      it "returns metadata identifying the pause" do
        reset_at = Time.zone.parse("2026-01-01 12:00:00")

        result = described_class.build(reset_at: reset_at, auto_resume: true)

        expect(result.metadata).to eq(
          "rate_limit_paused" => true,
          "reset_at" => reset_at.iso8601,
          "auto_resume" => true
        )
      end
    end

    context "when auto-resume is disabled" do
      it "explains the user must resend manually" do
        result = described_class.build(reset_at: nil, auto_resume: false)

        expect(result.content).to include("Automatic resend is disabled")
        expect(result.content).to include("Send your message again")
      end
    end

    context "without a known reset time" do
      it "omits the reset clause and metadata key" do
        result = described_class.build(reset_at: nil, auto_resume: true)

        expect(result.content).not_to include("resets at")
        expect(result.metadata).not_to have_key("reset_at")
      end
    end
  end
end
