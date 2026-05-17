# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::ProviderResolver do
  def create_pi_tenant_key_setup
    account = create(:account)
    owner = create(:user, :owner, account: account)
    project = create(:project, account: account, created_by: owner)
    pi_provider = create(:provider, user: owner, provider_key: "pi")
    owner.settings.update!(default_agent_provider: pi_provider.routing_key)

    api_key = create(:provider_api_key, user: owner, api_service_type: "deepseek", api_key: "sk-deepseek")
    create(:tenant_setting, account: account,
      provider_preferences: {
        "api_key_ids" => { "deepseek" => api_key.id },
        "model_preferences" => { "pi" => "deepseek-chat" }
      })

    [ project, owner, api_key ]
  end

  describe ".call" do
    it "honors tenant API keys owned by another account member" do
      account = create(:account)
      owner = create(:user, :owner, account: account)
      member = create(:user, :member, account: account)
      project = create(:project, account: account, created_by: owner)
      api_key = create(:provider_api_key, user: member, api_service_type: "anthropic")
      create(:tenant_setting, account: account,
        provider_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")
      provider = Provider.find(provider_id)

      expect(agent_type).to eq("claude_code")
      expect(provider).to have_attributes(
        user: owner,
        provider_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "uses the project-level preferred_agent_type from model_preferences" do
      project = create(:project)
      owner = project.created_by
      cursor_provider = create(:provider, user: owner, provider_key: "cursor")
      project.update!(model_preferences: project.model_preferences.merge("preferred_agent_type" => "cursor"))

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")

      expect(agent_type).to eq("cursor")
      expect(provider_id).to eq(cursor_provider.id)
    end

    it "prefers requested_agent_type over project-level preferred_agent_type" do
      project = create(:project)
      owner = project.created_by
      create(:provider, user: owner, provider_key: "cursor")
      create(:provider, user: owner, provider_key: "codex")
      project.update!(model_preferences: project.model_preferences.merge("preferred_agent_type" => "cursor"))

      _provider_id, agent_type = described_class.call(
        project: project,
        goal: "create_pr",
        requested_agent_type: "codex"
      )

      expect(agent_type).to eq("codex")
    end

    it "ignores requested provider ids from another account" do
      project = create(:project)
      other_owner = create(:user, :owner)
      other_provider = create(:provider, user: other_owner, provider_key: "codex")

      provider_id, agent_type = described_class.call(
        project: project,
        goal: "create_pr",
        requested_provider_id: other_provider.id
      )

      expect(provider_id).not_to eq(other_provider.id)
      expect(Provider.find(provider_id)).to eq(project.created_by.providers.find_by!(provider_key: "claude"))
      expect(agent_type).to eq("claude_code")
    end

    it "falls back to the first enabled runnable provider when the saved setting points to a disabled provider" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor])

      project = create(:project)
      owner = project.created_by
      cursor_provider = create(:provider, user: owner, provider_key: "cursor")
      owner.settings.update!(default_agent_provider: "cursor")
      cursor_provider.update!(enabled_for_agent_runs: false)

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")

      expect(provider_id).to eq(owner.providers.find_by!(provider_key: "claude").id)
      expect(agent_type).to eq("claude_code")
    end

    it "prefers the automated runnable provider family for tenant API-key selection" do
      project = create(:project)
      owner, settings = project.created_by, project.created_by.settings
      cursor_provider = create(:provider, user: owner, provider_key: "cursor")
      codex_provider = create(:provider, user: owner, provider_key: "codex")
      owner.settings.update!(default_agent_provider: "cursor", provider_selection_mode: "round_robin")
      allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project: project, strict: false).and_return(settings)
      allow(settings).to receive(:select_automated_provider_identifier).with(goal: "create_pr").and_return(codex_provider.routing_key)

      api_key = create(:provider_api_key, user: owner, api_service_type: "openai")
      create(:tenant_setting, account: project.account,
        provider_preferences: { "api_key_ids" => { "openai" => api_key.id } })

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")
      provider = Provider.find(provider_id)

      expect(agent_type).to eq("codex")
      expect(provider).to have_attributes(
        user: owner,
        provider_key: "codex",
        auth_type: "api_key",
        provider_api_key: api_key
      )
      expect(provider_id).not_to eq(cursor_provider.id)
    end

    it "keeps the configured provider family for tenant API-key selection when the automated provider is stale" do
      project = create(:project)
      owner = project.created_by
      settings = owner.settings
      cursor_provider = create(:provider, user: owner, provider_key: "cursor")
      owner.settings.update!(default_agent_provider: "cursor")
      cursor_provider.update!(enabled_for_agent_runs: false)
      allow(AgentRuns::UserSettingsResolver).to receive(:call).with(project: project, strict: false).and_return(settings)
      allow(settings).to receive(:select_automated_provider_identifier).with(goal: "create_pr").and_return(cursor_provider.routing_key)

      api_key = create(:provider_api_key, user: owner, api_service_type: "anthropic")
      create(:tenant_setting, account: project.account,
        provider_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")
      provider = Provider.find(provider_id)

      expect(agent_type).to eq("cursor")
      expect(provider).to have_attributes(
        user: owner,
        provider_key: "cursor",
        auth_type: "api_key",
        provider_api_key: api_key
      )
    end

    it "does not create a tenant API-key provider for a non-runnable configured provider key" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude])
      allow(ProviderSupport).to receive(:container_executable_provider_key?) do |key|
        key == "claude"
      end

      project = create(:project)
      owner = project.created_by
      # Use a valid provider key (cursor) but stub it as non-runnable
      stale_provider = create(:provider, user: owner, provider_key: "cursor", enabled_for_agent_runs: true)
      owner.settings.update!(default_agent_provider: "cursor")

      api_key = create(:provider_api_key, user: owner, api_service_type: "anthropic")
      create(:tenant_setting, account: project.account,
        provider_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")

      # Should not select the non-runnable cursor provider via tenant API key
      expect(provider_id).not_to eq(stale_provider.id)
      resolved_provider = Provider.find(provider_id)
      expect(resolved_provider.provider_key).to eq("claude")
      expect(agent_type).to eq("claude_code")
    end

    it "materializes a Pi tenant API-key provider with matching provider config" do
      project, owner, api_key = create_pi_tenant_key_setup
      provider_id, agent_type = described_class.call(project: project, goal: "create_pr")
      provider = Provider.find(provider_id)

      expect(agent_type).to eq("pi")
      expect(provider).to have_attributes(
        user: owner,
        provider_key: "pi",
        auth_type: "api_key",
        provider_api_key: api_key
      )
      expect(provider.pi_api_provider).to eq("deepseek")
      expect(provider.pi_model_id).to eq("deepseek-chat")
    end

    it "falls back to a nil provider id with the first runnable agent type when no owner providers are available" do
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[codex])

      project = build_stubbed(:project)
      allow(project).to receive(:effective_owner).and_return(nil)

      provider_id, agent_type = described_class.new(project: project, goal: "create_pr").send(:fallback_from_settings)

      expect(provider_id).to be_nil
      expect(agent_type).to eq("codex")
    end
  end
end
