# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::BotIdentity do
  before do
    allow(described_class).to receive_messages(
      configured_app_slug: nil,
      configured_name: nil,
      configured_email: nil
    )
  end

  describe ".for_git" do
    it "uses configured metadata and derives the email from the app slug when needed" do
      allow(described_class).to receive_messages(
        configured_app_slug: "paid-agents",
        configured_name: "Paid Agent"
      )

      identity = described_class.for_git

      expect(identity.app_slug).to eq("paid-agents")
      expect(identity.name).to eq("Paid Agent")
      expect(identity.email).to eq("paid-agents@paid-agents.com")
    end

    it "uses the configured email when present" do
      allow(described_class).to receive_messages(
        configured_app_slug: "paid-agents",
        configured_name: "Paid Agent",
        configured_email: "commits@example.com"
      )

      identity = described_class.for_git

      expect(identity.email).to eq("commits@example.com")
    end

    it "falls back to the legacy identity when no paid-agent metadata is configured" do
      identity = described_class.for_git

      expect(identity.app_slug).to eq("paid-agents")
      expect(identity.name).to eq("Paid Agent")
      expect(identity.email).to eq("agent@paid-agents.com")
    end
  end

  describe ".bot_login" do
    it "uses the resolved app slug" do
      allow(described_class).to receive(:configured_app_slug).and_return("self-hosted-paid")

      expect(described_class.bot_login).to eq("self-hosted-paid[bot]")
    end
  end
end
