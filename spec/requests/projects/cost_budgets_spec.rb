# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::CostBudgets" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  before { sign_in user }

  describe "POST /projects/:project_id/cost_budgets" do
    context "when user has update permission" do
      before do
        user.add_role(:admin, account)
      end

      it "creates a new budget" do
        expect {
          post project_cost_budgets_path(project), params: {
            cost_budget: { budget_type: "daily", limit_dollars: "10.00", alert_threshold_percent: 80 }
          }
        }.to change(CostBudget, :count).by(1)

        expect(response).to redirect_to(project_cost_dashboard_path(project))
        budget = project.cost_budgets.last
        expect(budget.limit_cents).to eq(1000)
        expect(budget.budget_type).to eq("daily")
      end

      it "renders errors for invalid budget" do
        post project_cost_budgets_path(project), params: {
          cost_budget: { budget_type: "daily", limit_dollars: "0", alert_threshold_percent: 80 }
        }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "PATCH /projects/:project_id/cost_budgets/:id" do
    let!(:budget) { create(:cost_budget, project: project, budget_type: "daily", limit_cents: 1000) }

    context "when user has update permission" do
      before do
        user.add_role(:admin, account)
      end

      it "updates the budget limit" do
        patch project_cost_budget_path(project, budget), params: {
          cost_budget: { limit_dollars: "20.00" }
        }

        expect(response).to redirect_to(project_cost_dashboard_path(project))
        expect(budget.reload.limit_cents).to eq(2000)
      end
    end
  end

  describe "DELETE /projects/:project_id/cost_budgets/:id" do
    let!(:budget) { create(:cost_budget, project: project, budget_type: "daily", limit_cents: 1000) }

    context "when user has update permission" do
      before do
        user.add_role(:admin, account)
      end

      it "destroys the budget" do
        expect {
          delete project_cost_budget_path(project, budget)
        }.to change(CostBudget, :count).by(-1)

        expect(response).to redirect_to(project_cost_dashboard_path(project))
      end
    end
  end
end
