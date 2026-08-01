# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::HealthCheck" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/health" do
    before { sign_in user }

    it "renders the not-run-yet state when no result is cached" do
      get project_health_check_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No health check has been run yet")
    end

    it "renders cached findings grouped by scope" do
      finding = HealthChecks::Finding.new(
        check: "HealthChecks::Checks::Project::EmptyAllowlist",
        scope: :project,
        severity: :error,
        message: "Allowed GitHub usernames is empty."
      )
      result = HealthChecks::Result.new(findings: [ finding ], checked_at: Time.current, duration_ms: 10)
      allow(HealthChecks::Cache).to receive(:read).with(project).and_return(result)

      get project_health_check_path(project)

      expect(response.body).to include("Project")
      expect(response.body).to include("Empty Allowlist")
      expect(response.body).to include("Allowed GitHub usernames is empty.")
    end

    it "renders the all-clear card when the result is healthy" do
      result = HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 5)
      allow(HealthChecks::Cache).to receive(:read).with(project).and_return(result)

      get project_health_check_path(project)

      expect(response.body).to include("All checks passed")
    end

    it "includes the Turbo Frame and stream subscription for completion-driven refresh" do
      get project_health_check_path(project)

      expect(response.body).to include('turbo-frame id="health_check_result"')
      expect(response.body).to include("Turbo::StreamsChannel")
    end
  end

  describe "POST /projects/:project_id/health/refresh" do
    before { sign_in user }

    it "enqueues ProjectHealthCheckJob and redirects to show for HTML requests" do
      expect do
        post refresh_project_health_check_path(project)
      end.to have_enqueued_job(ProjectHealthCheckJob).with(project.id)

      expect(response).to redirect_to(project_health_check_path(project))
    end

    it "responds with a Turbo Stream re-running state for Turbo requests" do
      expect do
        post refresh_project_health_check_path(project), as: :turbo_stream
      end.to have_enqueued_job(ProjectHealthCheckJob).with(project.id)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("Re-running health checks")
    end
  end
end
