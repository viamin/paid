# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::FallbackRunners do
  describe ".for" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:chat_session) { create(:chat_session, account: account, created_by: user, runner: primary_runner) }
    let(:primary_runner) { create_openrouter_runner(name: "Primary") }

    it "allows fallback to another API-key runner with the same runner key" do
      fallback_runner = create_openrouter_runner(name: "Fallback")
      user.settings.update!(kb_chat_fallback_runners: [ "opencode" ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ fallback_runner ])
    end

    it "does not return the exact excluded runner for routing-key fallbacks" do
      user.settings.update_columns(kb_chat_fallback_runners: [ primary_runner.routing_key ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end
  end

  def create_openrouter_runner(name:)
    create(:runner, :api_key, user: user, runner_key: "opencode", name: name,
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
  end
end
