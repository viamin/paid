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

    it "returns no fallbacks when the user has no fallback runners configured" do
      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    it "does not return the session runner as its own fallback" do
      expect(described_class.for(chat_session: chat_session)).to eq([])
    end

    it "prefers a runner selected after the current attempt started" do
      # @spec CHAT-API-006
      selected_runner = create_openrouter_runner(name: "Selected")
      selected_runner.update!(enabled_for_fallback: false)
      chat_session.runner
      ChatSession.where(id: chat_session.id).update_all(runner_id: selected_runner.id)

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ selected_runner ])
    end

    it "falls back to another enabled chat runner when no explicit fallback is configured" do
      # @spec CHAT-API-006
      fallback_runner = create_openrouter_runner(name: "Automatic")

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ fallback_runner ])
    end

    it "does not automatically use runners disabled for fallback" do
      # @spec CHAT-API-006
      create_openrouter_runner(name: "Disabled").update!(enabled_for_fallback: false)

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    it "does not use configured runners disabled for fallback" do
      disabled = create_openrouter_runner(name: "Disabled")
      disabled.update!(enabled_for_fallback: false)
      user.settings.update_columns(kb_chat_fallback_runners: [ disabled.routing_key, "opencode" ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    it "does not automatically use subscription runners" do
      create(:runner, user: user, runner_key: "codex", auth_type: "subscription", enabled_for_chat: true, enabled_for_fallback: true)

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    # @spec RUNNER-USAGE-006
    it "does not use configured chat fallback runners disabled for chat" do
      chat_disabled = create_openrouter_runner(name: "Chat Disabled")
      chat_disabled.update!(enabled_for_chat: false, enabled_for_fallback: true)
      user.settings.update_columns(kb_chat_fallback_runners: [ chat_disabled.routing_key ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    # @spec RUNNER-USAGE-006
    it "does not use configured chat fallback runners disabled for chat when referenced by runner key" do
      chat_disabled = create_openrouter_runner(name: "Chat Disabled")
      chat_disabled.update!(enabled_for_chat: false, enabled_for_fallback: true)
      user.settings.update_columns(kb_chat_fallback_runners: [ "opencode" ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    # @spec RUNNER-USAGE-007
    it "does not automatically use chat fallback runners disabled for chat" do
      create_openrouter_runner(name: "Automatic Chat Disabled").update!(enabled_for_chat: false, enabled_for_fallback: true)

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([])
    end

    # @spec RUNNER-USAGE-009
    it "keeps chat fallback eligibility when agent runs are disabled" do
      agent_disabled = create_openrouter_runner(name: "Chat Only")
      agent_disabled.update!(enabled_for_agent_runs: false, enabled_for_chat: true, enabled_for_fallback: true)

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ agent_disabled ])
    end
  end

  describe ".notice_for" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:runner) { create_openrouter_runner(name: "Fallback") }

    it "describes a rate limit cause" do
      error = AgentHarness::RateLimitError.new("API rate limit exceeded")

      message = described_class.notice_for(error: error, runner: runner)

      expect(message).to include("hit a rate limit")
      expect(message).to include("Switching to #{runner.display_name} and continuing.")
    end

    it "describes a generic provider failure cause" do
      error = AgentHarness::Error.new("boom")

      message = described_class.notice_for(error: error, runner: runner)

      expect(message).to include("could not complete the request")
      expect(message).to include("Switching to #{runner.display_name} and continuing.")
    end
  end

  def create_openrouter_runner(name:)
    create(:runner, :api_key, user: user, runner_key: "opencode", name: name,
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
  end
end
