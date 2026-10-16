# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::RunnerModelOptions do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:runner) do
    create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openai"),
      config: { "opencode" => { "api_provider" => "openai", "model" => "gpt-5.6-luna" } })
  end

  before do
    create(:llm_model, :openai, model_id: "gpt-5.6-luna", tier: "low", capability_score: 9.0)
    create(:llm_model, :openai, model_id: "gpt-5.6-terra", tier: "mid", capability_score: 9.0)
    create(:llm_model, :openai, model_id: "gpt-5.6-sol", tier: "high", capability_score: 9.0)
    create(:llm_model, :openai, model_id: "gpt-5.6-extra", tier: "high", capability_score: 10.0)
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "offers only the curated OpenAI Low, Medium, and High choices" do
    options = described_class.options_for([ runner ])

    expect(options.map(&:model_id)).to eq(%w[gpt-5.6-luna gpt-5.6-terra gpt-5.6-sol])
    expect(options.map(&:label)).to eq([
      "#{runner.display_name} — Low: gpt-5.6-luna",
      "#{runner.display_name} — Medium: gpt-5.6-terra",
      "#{runner.display_name} — High: gpt-5.6-sol"
    ])
  end

  # @spec CHAT-SESSION-PREFERENCES-003 CHAT-API-019
  it "excludes free-policy runners whose model is selected dynamically" do
    free_runner = create(:runner, :api_key, user: user, runner_key: "opencode",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

    expect(described_class.options_for([ free_runner ])).to be_empty
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "excludes a tier with fresh account-specific unavailable evidence" do
    model = LlmModel.find_by!(model_id: "gpt-5.6-luna")
    create(:model_availability_check, llm_model: model, account: account, runner_key: runner.runner_key,
      auth_type: "api_key", status: "unavailable", source: "runtime_rejection", checked_at: Time.current,
      expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now)

    expect(described_class.options_for([ runner ]).map(&:model_id)).to eq(%w[gpt-5.6-terra gpt-5.6-sol])
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "excludes choices above the linked project's model tier limit" do
    project = create(:project, account: account, model_preferences: { "max_tier" => "low" })

    options = described_class.options_for([ runner ], projects: [ project ])

    expect(options.map(&:model_id)).to eq([ "gpt-5.6-luna" ])
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "excludes models disabled by an operator" do
    LlmModel.find_by!(model_id: "gpt-5.6-terra").update!(operator_active_override: false)

    expect(described_class.options_for([ runner ]).map(&:model_id)).to eq(%w[gpt-5.6-luna gpt-5.6-sol])
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "excludes choices above the linked project's execution policy tier limit" do
    project = create(:project, account: account)
    policy = create(:coordination_policy, :active, account: account, project: project,
      policy_type: "execution", policy_key: "agent_execution")
    policy.current_version.update!(rules: { "controls" => { "max_model_tier" => "low" } })

    options = described_class.options_for([ runner ], projects: [ project ])

    expect(options.map(&:model_id)).to eq([ "gpt-5.6-luna" ])
  end

  # @spec CHAT-SESSION-PREFERENCES-003
  it "loads catalog and availability evidence once for all curated choices" do
    20.times do |index|
      create(:llm_model, :openai, model_id: "gpt-5.6-catalog-#{index}", tier: "high", capability_score: 1.0)
    end

    queries = capture_queries { described_class.options_for([ runner ]) }

    expect(queries.grep(/FROM "model_availability_checks"/i).size).to eq(1)
    expect(queries.grep(/FROM "llm_models".*gpt-5.6-catalog-/i)).to be_empty
  end
end
