# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::SensitiveDataFreeModel do
  it "returns a warning for sensitive projects pinned to a risky free model" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    project = build(
      :project,
      data_classification: "confidential",
      model_preferences: { "required_model_id" => model.model_id }
    )

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :warning,
        message: "Sensitive project resolves to free model free-model with possible training risk."
      )
    )
  end

  it "returns no findings for sensitive projects pinned to an OpenRouter-routed free model" do
    model = create(:llm_model, :free, model_id: "openrouter-free-model", catalog_source: "openrouter_sync")
    project = build(
      :project,
      data_classification: "restricted",
      model_preferences: { "required_model_id" => model.model_id }
    )

    expect(described_class.call(project)).to eq([])
  end

  it "returns no findings for sensitive projects pinned to a risky free model via openrouter_free" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    project = build(
      :project,
      data_classification: "confidential",
      model_preferences: {
        "required_model_id" => model.model_id,
        "preferred_agent_type" => "openrouter_free"
      }
    )

    expect(described_class.call(project)).to eq([])
  end

  it "returns no findings when the default create_pr runner routes through OpenRouter" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    owner = create(:user)
    openrouter_key = create(:provider_api_key, user: owner, api_service_type: "openrouter")
    openrouter_runner = create(
      :runner,
      user: owner,
      runner_key: "openrouter_free",
      auth_type: "api_key",
      provider_api_key: openrouter_key
    )
    owner.settings.update!(default_agent_runner: openrouter_runner.routing_key)
    project = build(
      :project,
      created_by: owner,
      account: owner.account,
      data_classification: "confidential",
      model_preferences: { "required_model_id" => model.model_id }
    )

    expect(described_class.call(project)).to eq([])
  end

  it "returns no findings when the automated create_pr runner routes through OpenRouter" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    owner = create(:user)
    settings = owner.settings
    openrouter_runner = instance_double(Runner, runner_key: "openrouter_free")
    selected_settings = instance_double(UserSetting)
    project = build(
      :project,
      created_by: owner,
      account: owner.account,
      data_classification: "confidential",
      model_preferences: { "required_model_id" => model.model_id }
    )

    allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project: project, strict: false).and_return(settings)
    allow(settings).to receive(:dup).and_return(selected_settings)
    allow(selected_settings).to receive(:select_automated_runner_identifier)
      .with(goal: "create_pr")
      .and_return("runner-123")
    allow(Runner).to receive(:for_identifier).with(owner, "runner-123").and_return(openrouter_runner)

    expect(described_class.call(project)).to eq([])
  end

  it "returns a warning when a sensitive project inherits a risky free tenant model preference" do
    model = create(:llm_model, :free, model_id: "free-tenant-model", catalog_source: "manual")
    owner = create(:user)
    create(:tenant_setting, account: owner.account, runner_preferences: {
      "model_preferences" => { "claude" => model.model_id }
    })
    project = create(
      :project,
      created_by: owner,
      account: owner.account,
      data_classification: "confidential"
    )

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :warning,
        message: "Sensitive project resolves to free model free-tenant-model with possible training risk."
      )
    )
  end

  it "ignores tenant model preferences whose provider the project blocks" do
    model = create(:llm_model, :free, provider: "anthropic", model_id: "free-tenant-model", catalog_source: "manual")
    owner = create(:user)
    create(:tenant_setting, account: owner.account, runner_preferences: {
      "model_preferences" => { "claude" => model.model_id }
    })
    project = create(
      :project,
      created_by: owner,
      account: owner.account,
      data_classification: "restricted",
      model_preferences: {
        "llm_providers" => { "allowlist" => [ "openai" ] }
      }
    )

    expect(described_class.call(project)).to eq([])
  end
end
