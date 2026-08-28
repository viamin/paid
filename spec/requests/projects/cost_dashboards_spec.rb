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

      def create_completed_infra_execution_usage(run)
        create(:execution_usage,
          agent_run: run,
          runner_backend: "local",
          provisioned_at: 2.hours.ago,
          execution_started_at: 2.hours.ago,
          completed_at: 1.hour.ago,
          terminated_at: 1.hour.ago,
          billed_duration_seconds: 3600,
          termination_reason: "completed",
          infra_cost_cents: 120,
          rate_cents_per_hour: 120)
      end

      it "renders the cost dashboard" do
        get project_cost_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Cost Dashboard")
      end

      it "shows cost summary cards when cost data exists" do
        project.update!(total_cost_cents: 100)

        get project_cost_dashboard_path(project)

        expect(response.body).to include("Total Cost")
        expect(response.body).to include("Cost This Month")
        expect(response.body).to include("Cost Today")
        expect(response.body).to include("Avg Cost / Run")
      end

      it "hides cost summary cards when no cost data" do
        get project_cost_dashboard_path(project)

        expect(response.body).to include("No cost data available yet.")
        expect(response.body).not_to include('<dt class="truncate text-sm font-medium text-gray-500">Total Cost</dt>')
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

      it "renders summary cards from combined cost for an infra-only project" do
        # An infra-only project has zero token spend but a recorded
        # ExecutionUsage row. The cards must surface the new
        # accounting instead of collapsing the summary row to
        # "No cost data available yet."
        run = create(:agent_run, project: project, status: "completed", cost_cents: 0)
        create_completed_infra_execution_usage(run)
        project.update!(total_cost_cents: 0)

        get project_cost_dashboard_path(project)

        expect(response.body).to include('<dt class="truncate text-sm font-medium text-gray-500">Total Cost</dt>')
        expect(response.body).to include("$1.20")

        # The LLM-only breakdown sections must not silently disappear just
        # because the combined total (shown above) is driven by infra spend
        # rather than token spend — they render, explicitly labeled as
        # LLM-only, instead of vanishing next to a non-zero "Total Cost" card.
        expect(response.body).to include("Cost by Outcome (LLM Only)")
        expect(response.body).to include("Cost by Goal Type (LLM Only)")
        expect(response.body).to include("Cost by Tier (LLM Only)")
        expect(response.body).to include("Cost Trend (Last 30 Days) (LLM Only)")
        expect(response.body).to include("No LLM cost data available yet.")
      end

      it "renders summary cards from combined cost when only pending infra spend exists" do
        # Pending infra spend (no ExecutionUsage row, live machine) must
        # also surface the cards for an otherwise-zero project.
        create(:agent_run, project: project, status: "running", cost_cents: 0,
          provisioning_started_at: 30.minutes.ago,
          started_at: 25.minutes.ago,
          external_metadata: { "infrastructure_spend" => { "rate_cents_per_hour" => 120 } })
        project.update!(total_cost_cents: 0)

        get project_cost_dashboard_path(project)

        expect(response.body).to include('<dt class="truncate text-sm font-medium text-gray-500">Total Cost</dt>')
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
