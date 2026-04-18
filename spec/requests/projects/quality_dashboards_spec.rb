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

      it "shows gate status alert when thresholds are breached" do
        threshold = create(:quality_gate_threshold, project: project, min_threshold: 0.6)
        run = create(:agent_run, project: project)
        metric = create(:quality_metric, agent_run: run, composite_score: 0.4)
        create(:quality_gate_event,
          project: project, quality_gate_threshold: threshold,
          quality_metric: metric, event_type: "trigger",
          score_value: 0.4, threshold_value: 0.6)

        get project_quality_dashboard_path(project)

        expect(response.body).to include("quality gate")
        expect(response.body).to include("currently breached")
      end

      it "shows model comparison section" do
        run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: run, composite_score: 0.85)

        get project_quality_dashboard_path(project)

        expect(response.body).to include("Model Comparison")
      end

      it "shows export button" do
        run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: run, composite_score: 0.85)

        get project_quality_dashboard_path(project)

        expect(response.body).to include("Export CSV")
      end
    end
  end

  describe "GET /projects/:project_id/quality_dashboard/export" do
    context "when not authenticated" do
      it "does not allow access" do
        get export_project_quality_dashboard_path(project, format: :csv)
        expect(response).to have_http_status(:unauthorized).or redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns a CSV file" do
        run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: run, composite_score: 0.85)

        get export_project_quality_dashboard_path(project, format: :csv)

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("text/csv")
        expect(response.body).to include("composite_score")
      end

      it "returns empty CSV when no data" do
        get export_project_quality_dashboard_path(project, format: :csv)

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("text/csv")
      end
    end
  end
end
