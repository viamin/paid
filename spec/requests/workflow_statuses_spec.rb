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

      it "renders the workflow status page" do
        get project_workflow_status_path(project)
        expect(response).to have_http_status(:ok)
      end

      it "shows the GitHub Polling section" do
        get project_workflow_status_path(project)
        expect(response.body).to include("GitHub Polling")
      end

      it "shows 'Not started' when no poll workflow exists" do
        get project_workflow_status_path(project)
        expect(response.body).to include("Not started")
      end

      it "shows 'Active' when poll workflow is running" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")

        get project_workflow_status_path(project)
        expect(response.body).to include("Active")
      end

      it "shows workflow status when poll workflow is not running" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "completed")

        get project_workflow_status_path(project)
        expect(response.body).to include("Completed")
      end

      it "shows recent non-poll workflows" do
        create(:workflow_state, :with_project,
          project: project,
          workflow_type: "AgentExecutionWorkflow",
          status: "completed")

        get project_workflow_status_path(project)
        expect(response.body).to include("AgentExecutionWorkflow")
      end

      it "excludes GitHubPoll workflows from the recent list" do
        create(:workflow_state,
          project: project,
          temporal_workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPoll",
          status: "running")

        get project_workflow_status_path(project)
        # The table should not contain GitHubPoll rows
        expect(response.body).not_to include("<td class=\"whitespace-nowrap py-4 pl-4 pr-3 text-sm text-gray-900 sm:pl-6\">GitHubPoll</td>")
      end

      it "shows empty state when no workflows exist" do
        get project_workflow_status_path(project)
        expect(response.body).to include("No workflow executions yet.")
      end

      it "limits recent workflows to 10" do
        12.times do |i|
          create(:workflow_state,
            project: project,
            workflow_type: "AgentExecutionWorkflow",
            status: "completed",
            started_at: i.hours.ago,
            completed_at: (i.hours.ago + 5.minutes))
        end

        get project_workflow_status_path(project)
        expect(response.body.scan("AgentExecutionWorkflow").count).to eq(10)
      end

      it "includes Temporal UI links" do
        get project_workflow_status_path(project)
        expect(response.body).to include("View in Temporal UI")
      end

      it "includes auto-refresh meta tag when workflows are running" do
        create(:workflow_state,
          project: project,
          workflow_type: "AgentExecutionWorkflow",
          status: "running")

        get project_workflow_status_path(project)
        expect(response.body).to include('http-equiv="refresh" content="5"')
      end

      it "does not include auto-refresh when no workflows are running" do
        create(:workflow_state,
          project: project,
          workflow_type: "AgentExecutionWorkflow",
          status: "completed",
          completed_at: Time.current)

        get project_workflow_status_path(project)
        expect(response.body).not_to include('http-equiv="refresh"')
      end

      it "does not allow viewing workflow status for other accounts' projects" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)

        get project_workflow_status_path(other_project)
        expect(response).to have_http_status(:not_found)
      end

      it "renders within a turbo_frame" do
        get project_workflow_status_path(project)
        expect(response.body).to include('turbo-frame id="workflow-status"')
      end
    end
  end
end
