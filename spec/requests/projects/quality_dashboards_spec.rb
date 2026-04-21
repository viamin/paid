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

      it "renders configurable quality thresholds" do
        get project_quality_dashboard_path(project)

        expect(response.body).to include("Quality Thresholds")
        expect(response.body).to include("CI Passed")
        expect(response.body).to include("PR Merged")
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

  describe "PATCH /projects/:project_id/quality_thresholds" do
    context "when authenticated" do
      before { sign_in user }

      it "creates a project override" do
        patch project_quality_thresholds_path(project), params: {
          quality_thresholds: {
            "0" => {
              metric_type: "ci_passed",
              goal_type: "create_pr",
              min_value: "0.75",
              override: "1",
              enabled: "1"
            }
          }
        }

        expect(response).to redirect_to(project_quality_dashboard_path(project))
        threshold = project.quality_thresholds.find_by!(metric_type: "ci_passed", goal_type: "create_pr")
        expect(threshold.min_value).to eq(0.75)
      end

      it "removes a project override when inheritance is selected" do
        create(:quality_threshold, :project_override,
          project: project,
          metric_type: "ci_passed",
          goal_type: "create_pr")

        patch project_quality_thresholds_path(project), params: {
          quality_thresholds: {
            "0" => {
              metric_type: "ci_passed",
              goal_type: "create_pr",
              min_value: "0.75",
              override: "0",
              enabled: "1"
            }
          }
        }

        expect(project.quality_thresholds.where(metric_type: "ci_passed", goal_type: "create_pr")).to be_empty
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
