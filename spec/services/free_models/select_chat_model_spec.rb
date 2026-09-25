# frozen_string_literal: true

require "rails_helper"

RSpec.describe FreeModels::SelectChatModel do
  let(:user) { create(:user) }
  let(:runner) do
    create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      enabled_for_agent_runs: false, enabled_for_fallback: false, enabled_for_chat: true,
      config: { "opencode" => { "model_policy" => "free" } })
  end

  def free_model(**attributes)
    create(:llm_model, :free, catalog_source: "openrouter_sync", supports_tools: true,
      context_window: 128_000, metadata: { "architecture" => { "output_modalities" => [ "text" ] } },
      **attributes)
  end

  # @spec CHAT-API-018
  it "retains an eligible session model and sees catalog changes on subsequent selections" do
    preferred = free_model(capability_score: 6)
    better = free_model(capability_score: 9)
    expect(described_class.call(runner: runner, preferred_model_id: preferred.model_id)).to eq(preferred)
    preferred.update!(active: false)
    expect(described_class.call(runner: runner, preferred_model_id: preferred.model_id)).to eq(better)
    newest = free_model(capability_score: 10)
    expect(described_class.call(runner: runner)).to eq(newest)
  end

  # @spec CHAT-API-018, FREE-MODEL-SYNC-008
  it "uses the next scheduled sync snapshot without rewriting runner preferences" do
    payload = { "id" => "vendor/old:free", "name" => "Old", "context_length" => 128_000,
      "pricing" => { "prompt" => "0", "completion" => "0" }, "supported_parameters" => [ "tools" ],
      "architecture" => { "output_modalities" => [ "text" ] } }
    stub_request(:get, FreeModels::Client::API_URL).to_return(
      { body: { data: [ payload ] }.to_json },
      { body: { data: [ payload.merge("id" => "vendor/new:free", "name" => "New") ] }.to_json }
    )
    FreeModels::SyncJob.perform_now
    selected = described_class.call(runner: runner)
    tiers = runner.tier_model_ids.deep_dup
    expect(selected.model_id).to eq("vendor/old:free")

    FreeModels::SyncJob.perform_now
    expect(described_class.call(runner: runner, preferred_model_id: selected.model_id).model_id).to eq("vendor/new:free")
    expect(runner.reload.tier_model_ids).to eq(tiers)
  end

  # @spec CHAT-API-018
  [ { supports_tools: false }, { context_window: 127_999 }, { active: false },
    { pricing_tier: "paid" }, { catalog_source: "manual" }, { operator_active_override: false },
    { metadata: { "below_quality_bar" => true, "architecture" => { "output_modalities" => [ "text" ] } } },
    { metadata: { "architecture" => { "output_modalities" => [ "image" ] } } },
    { model_id: "openrouter/free" } ].each do |attributes|
    it "rejects an ineligible model with #{attributes.inspect}" do
      free_model(**attributes)
      expect { described_class.call(runner: runner) }.to raise_error(ChatSessions::LlmClientConfigurationError, /No eligible/)
    end
  end

  # @spec CHAT-API-018
  it "excludes expired and rate-limited models" do
    free_model(expires_at: 1.second.ago)
    limited = free_model
    runner.user.runner_states.create!(runner_name: runner.state_key).mark_model_rate_limited!(limited.model_id)
    eligible = free_model
    expect(described_class.call(runner: runner)).to eq(eligible)
  end

  # @spec CHAT-API-018
  it "honors project exclusions and provider restrictions" do
    excluded = free_model(provider: "openai")
    free_model(provider: "anthropic")
    eligible = free_model(provider: "openai")
    project = create(:project, model_preferences: { "excluded_free_model_ids" => [ excluded.model_id ],
      "llm_providers" => { "allowlist" => [ "openai" ] } })
    expect(described_class.call(runner: runner, project: project)).to eq(eligible)
  end

  # @spec CHAT-API-019
  %w[pi omp].each do |runner_key|
    it "rejects sensitive container chat on #{runner_key} without supported privacy routing" do
      project = create(:project, account: user.account, data_classification: "confidential")
      session = create(:chat_session, account: user.account, project: project, created_by: user)
      unsupported = build(:runner, user: user, runner_key: runner_key,
        config: { runner_key => { "model_policy" => "free" } })

      expect { described_class.for_session(runner: unsupported, chat_session: session, transport: :container) }
        .to raise_error(ChatSessions::LlmClientConfigurationError, /privacy routing/)
    end
  end
end
