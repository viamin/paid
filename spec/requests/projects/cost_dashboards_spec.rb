# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::CostDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/cost_dashboard" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get project_cost_dashboard_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the cost dashboard" do
        get project_cost_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Cost Dashboard")
      end

      it "shows cost summary cards" do
        get project_cost_dashboard_path(project)

        expect(response.body).to include("Total Cost")
        expect(response.body).to include("Cost This Month")
        expect(response.body).to include("Cost Today")
        expect(response.body).to include("Avg Cost / Run")
      end

      it "shows empty state when no cost data" do
        get project_cost_dashboard_path(project)

        expect(response.body).to include("$0.00")
      end

      it "shows cost data when token usages exist" do
        run = create(:agent_run, project: project, status: "completed", cost_cents: 500)
        create(:token_usage, agent_run: run, cost_cents: 500, llm_model: "claude-3-opus", request_type: "agent")
        project.update!(total_cost_cents: 500)

        get project_cost_dashboard_path(project)

        expect(response.body).to include("$5.00")
        expect(response.body).to include("Cost by Model")
        expect(response.body).to include("claude-3-opus")
      end

      it "shows budget status when budgets exist" do
        create(:cost_budget, :daily, project: project, limit_cents: 1000, current_usage_cents: 800)

        get project_cost_dashboard_path(project)

        expect(response.body).to include("Budget Limits")
        expect(response.body).to include("Daily Limit")
        expect(response.body).to include("$10.00")
      end
    end
  end
end
