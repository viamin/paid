# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::CostSnapshots" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/cost_snapshot" do
    before { sign_in user }

    it "renders the cost snapshot frame" do
      get project_cost_snapshot_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(turbo-frame id="cost_snapshot_project_#{project.id}"))
    end

    it "uses daily and monthly budget counters when available" do
      create(:cost_budget, :daily, project: project, limit_cents: 1_000, current_usage_cents: 125)
      create(:cost_budget, :monthly, project: project, limit_cents: 10_000, current_usage_cents: 2_500)

      get project_cost_snapshot_path(project)

      expect(response.body).to include("Today:")
      expect(response.body).to include("$1.25")
      expect(response.body).to include("This Month:")
      expect(response.body).to include("$25.00")
    end

    it "falls back to token usage aggregation when no period budgets exist" do
      run = create(:agent_run, project: project, status: "completed", cost_cents: 550)
      create(:token_usage, agent_run: run, cost_cents: 550, llm_model: "claude-3-opus", request_type: "agent")
      project.update!(total_cost_cents: 550)

      get project_cost_snapshot_path(project)

      expect(response.body).to include("Today:")
      expect(response.body).to include("$5.50")
      expect(response.body).to include("This Month:")
      expect(response.body).to include("$5.50")
    end
  end
end
