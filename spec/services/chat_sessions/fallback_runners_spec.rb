# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::FallbackRunners do
  describe "thinking effort on .switch!" do
    # @spec CHAT-THINKING-EFFORT-003
    it "clears a thinking effort unsupported by the fallback model" do
      account = create(:account)
      user = create(:user, account: account)
      runner = create(:runner, :api_key, user: user, runner_key: "claude",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"))
      ChatFallbackCatalog.seed_low_tier_model(model_id: "claude-haiku-4-5")
      session = create(:chat_session, account: account, created_by: user, metadata: { "thinking_effort" => "high" })

      described_class.switch!(chat_session: session, runner: runner)

      expect(session.reload.metadata["thinking_effort"]).to be_nil
    end
  end

  describe ".for" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:chat_session) { create(:chat_session, account: account, created_by: user, runner: primary_runner) }
    let(:primary_runner) { create_openrouter_runner(name: "Primary") }

    # @spec CHAT-API-019
    it "skips an empty free-model pool and retains a later healthy fallback" do
      free = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
        enabled_for_agent_runs: false, config: { "opencode" => { "model_policy" => "free" } })
      healthy = create_openrouter_runner(name: "Healthy")
      user.settings.update_columns(kb_chat_fallback_runners: [ free.routing_key, healthy.routing_key ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ healthy ])
      expect(chat_session.reload.runner).to eq(primary_runner)
    end

    # @spec MODEL-POLICY-024
    it "preserves the originating runner's ZDR requirement for fallback eligibility" do
      primary_runner.update!(zero_data_retention: true)
      fallback_runner = create(:runner, :api_key, user: user, runner_key: "claude",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"))
      ChatFallbackCatalog.seed_low_tier_model(model_id: "claude-haiku-4-5")
      user.settings.update_columns(kb_chat_fallback_runners: [ fallback_runner.routing_key ])

      expect(described_class.for(
        chat_session: chat_session,
        excluding: [ primary_runner ],
        required_zdr: true
      )).to eq([])
    end

    # @spec CHAT-API-026
    it "skips a non-free fallback whose curated Low tier is unavailable and retains a later healthy fallback" do
      claude_low = ChatFallbackCatalog.seed_low_tier_model(model_id: "claude-haiku-4-5")
      unavailable = create(:runner, :api_key, user: user, runner_key: "claude",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"))
      healthy = create_openrouter_runner(name: "Healthy")
      create(:model_availability_check, llm_model: claude_low, runner_key: "claude",
        auth_type: "api_key", status: "unavailable")
      user.settings.update_columns(kb_chat_fallback_runners: [ unavailable.routing_key, healthy.routing_key ])

      expect(described_class.for(chat_session: chat_session, excluding: [ primary_runner ])).to eq([ healthy ])
      expect(chat_session.reload.runner).to eq(primary_runner)
    end


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

  describe ".switch!" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    # @spec CHAT-API-026
    it "uses the same curated Low model and records its tier" do
      runner = create(:runner, :api_key, user: user, runner_key: "opencode",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "openai"),
        config: { "opencode" => { "api_provider" => "openai", "model" => "gpt-5.6-luna" } })
      model = LlmModel.find_or_initialize_by(model_id: "gpt-5.6-luna")
      model.assign_attributes(display_name: "GPT-5.6 Luna", provider: "openai", category: "coding",
        tier: "low", capability_score: 9.0, pricing_tier: "paid", catalog_source: "seeded",
        supports_tools: true, active: true)
      model.save!
      session = create(:chat_session, account: account, created_by: user)

      described_class.switch!(chat_session: session, runner: runner)

      expect(session.reload).to have_attributes(runner: runner, model: "gpt-5.6-luna")
      expect(session.metadata).to include("model_tier" => "low")
    end
  end

  def create_openrouter_runner(name:)
    ChatFallbackCatalog.seed_low_tier_models
    create(:runner, :api_key, user: user, runner_key: "opencode", name: name,
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2" } })
  end
end
