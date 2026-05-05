# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#agent_run_provider_display" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }

    it "uses the preloaded provider association without extra provider queries" do
      provider = create(:provider, user: user, provider_key: "codex")
      run = create(:agent_run, project: project, provider: provider, final_provider: nil)
      preloaded_run = AgentRun.includes(:provider).find(run.id)

      queries = capture_queries do
        expect(helper.agent_run_provider_display(preloaded_run)).to eq(provider.display_name)
      end

      provider_queries = queries.grep(/FROM "providers"/)
      expect(provider_queries).to be_empty
    end

    it "renders a placeholder for unsupported provider identifiers" do
      run = create(:agent_run, project: project, provider: nil, final_provider: "api", agent_type: "api")

      expect(helper.agent_run_provider_display(run)).to eq("Api")
    end
  end
end
