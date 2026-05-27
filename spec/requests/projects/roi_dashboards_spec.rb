# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::RoiDashboards" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/roi_dashboard" do
    it "redirects unauthenticated users" do
      get project_roi_dashboard_path(project)

      expect(response).to redirect_to(new_user_session_path)
    end

    it "renders the ROI dashboard for authenticated users" do
      sign_in user

      get project_roi_dashboard_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ROI, Evals & Benchmarking")
      expect(response.body).to include("Evaluation Framework")
      expect(response.body).to include("Add Benchmark")
    end
  end

  describe "POST /projects/:project_id/roi_benchmarks" do
    it "creates a benchmark entry" do
      sign_in user

      post project_roi_benchmarks_path(project), params: {
        roi_benchmark: {
          name: "Manual baseline",
          benchmark_type: "human_only",
          merge_rate: "52.5",
          average_cycle_time_hours: "48",
          rework_rate: "12.0",
          defect_escape_rate: "4.0",
          cost_per_accepted_pr_cents: "14000",
          accepted_pr_count: "5"
        }
      }

      expect(response).to redirect_to(project_roi_dashboard_path(project))
      expect(project.roi_benchmarks.find_by!(name: "Manual baseline")).to have_attributes(
        merge_rate: BigDecimal("52.5"),
        accepted_pr_count: 5
      )
    end
  end

  describe "DELETE /projects/:project_id/roi_benchmarks/:id" do
    it "removes a benchmark entry" do
      sign_in user
      benchmark = create(:roi_benchmark, project: project)

      delete project_roi_benchmark_path(project, benchmark)

      expect(response).to redirect_to(project_roi_dashboard_path(project))
      expect(project.roi_benchmarks.where(id: benchmark.id)).to be_empty
    end
  end

  describe "GET /projects/:project_id/roi_dashboard/export" do
    it "returns a CSV report" do
      sign_in user

      get export_project_roi_dashboard_path(project, format: :csv)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.body).to include("Executive Summary")
      expect(response.body).to include("Merge rate")
    end
  end
end
