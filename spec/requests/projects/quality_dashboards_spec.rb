# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::QualityDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/quality_dashboard" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get project_quality_dashboard_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the quality dashboard" do
        get project_quality_dashboard_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Quality Metrics")
      end

      it "shows empty state when no metrics exist" do
        get project_quality_dashboard_path(project)

        expect(response.body).to include("No quality metrics yet")
      end

      it "shows quality data when metrics exist" do
        run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: run, composite_score: 0.85)

        get project_quality_dashboard_path(project)

        expect(response.body).to include("Average Score")
        expect(response.body).to include("Quality Trends")
        expect(response.body).to include("Score Breakdown")
      end
    end
  end
end
