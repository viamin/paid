# frozen_string_literal: true

require "rails_helper"

RSpec.describe "WorkflowStatuses" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "GET /projects/:project_id/workflow_status" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_workflow_status_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the automation health page" do
        get project_workflow_status_path(project)
        expect(response).to have_http_status(:ok)
      end

      it "renders within a turbo_frame" do
        get project_workflow_status_path(project)
        expect(response.body).to include('turbo-frame id="workflow-status"')
      end

      it "shows 'Active' when poll workflow is running and project was recently polled" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")
        project.update_column(:last_polled_at, 30.seconds.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Active")
        expect(response.body).to include("monitoring this repository")
      end

      it "shows 'Not running' when no poll workflow exists" do
        get project_workflow_status_path(project)
        expect(response.body).to include("Not running")
        expect(response.body).to include("automatically restarted")
      end

      it "shows 'Not running' when poll workflow is not running" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "completed")

        get project_workflow_status_path(project)
        expect(response.body).to include("Not running")
      end

      it "shows 'Paused' when project is inactive" do
        project.update_column(:active, false)

        get project_workflow_status_path(project)
        expect(response.body).to include("Paused")
        expect(response.body).to include("monitoring is paused")
      end

      it "shows 'Delayed' when poll workflow is running but stale" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")
        # Set last_polled_at to well beyond the staleness threshold
        project.update_column(:last_polled_at, 10.minutes.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Delayed")
        expect(response.body).to include("behind schedule")
      end

      it "shows last checked time when available" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")
        project.update_column(:last_polled_at, 2.minutes.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Last checked")
        expect(response.body).to include("2 minutes ago")
      end

      it "shows poll interval for active projects" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")
        project.update_column(:last_polled_at, 30.seconds.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Check interval")
        expect(response.body).to include("Every #{project.poll_interval_seconds} seconds")
      end

      it "does not show poll interval for inactive projects" do
        project.update_column(:active, false)

        get project_workflow_status_path(project)
        expect(response.body).not_to include("Check interval")
      end

      it "does not allow viewing for other accounts' projects" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)

        get project_workflow_status_path(other_project)
        expect(response).to have_http_status(:not_found)
      end

      it "does not show raw Temporal terms" do
        get project_workflow_status_path(project)
        expect(response.body).not_to include("Not connected")
        expect(response.body).not_to include("View in Temporal UI")
        expect(response.body).not_to include("GitHubPoll")
      end
    end
  end
end
