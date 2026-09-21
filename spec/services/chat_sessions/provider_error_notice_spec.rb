# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ProviderErrorNotice do
  # @spec CHAT-API-017
  describe ".build" do
    it "explains that chat could not resume and asks the user to resend" do
      error = AgentHarness::ProviderError.new("provider unavailable")

      result = described_class.build(error: error)

      expect(result.content).to include("Chat could not resume")
      expect(result.content).to include("provider unavailable")
      expect(result.content).to include("send your message again")
    end

    it "falls back to a generic message when the error reports no message" do
      error = AgentHarness::ProviderError.new

      result = described_class.build(error: error)

      expect(result.content).to include("Chat could not resume")
      expect(result.content).to include("runner configuration")
    end

    it "tags the notice so the view renders it as a durable banner" do
      error = AgentHarness::ProviderError.new("provider unavailable")

      result = described_class.build(error: error)

      expect(result.metadata).to eq("provider_error_notice" => true)
    end
  end
end
