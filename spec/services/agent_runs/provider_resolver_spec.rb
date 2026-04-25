# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::ProviderResolver do
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
  end
end
