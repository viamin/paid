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
  end
end
