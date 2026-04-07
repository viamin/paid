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
      before do
        sign_in user
        # Default stub — tests that need specific states override this
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :not_found, running: false)
      end

      it "renders the automation health page" do
        get project_workflow_status_path(project)
        expect(response).to have_http_status(:ok)
      end

      it "renders within a turbo_frame" do
        get project_workflow_status_path(project)
        expect(response.body).to include('turbo-frame id="workflow-status"')
      end

      it "shows 'Active' when poll workflow is running and project was recently polled" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)
        project.update_column(:last_polled_at, 30.seconds.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Active")
        expect(response.body).to include("monitoring this repository")
      end

      it "shows 'Not running' when no poll workflow exists" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :not_found, running: false)

        get project_workflow_status_path(project)
        expect(response.body).to include("Not running")
        expect(response.body).to include("automatically restarted shortly if eligible")
      end

      it "shows 'Not running' when poll workflow is not running" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :completed, running: false)

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
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)
        # Set last_polled_at to well beyond the staleness threshold
        project.update_column(:last_polled_at, 10.minutes.ago)

        get project_workflow_status_path(project)
        expect(response.body).to include("Delayed")
        expect(response.body).to include("behind schedule")
      end

      it "shows last checked time when available" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)

        freeze_time do
          project.update_column(:last_polled_at, 2.minutes.ago)

          get project_workflow_status_path(project)
          expect(response.body).to include("Last checked")
          expect(response.body).to include("2 minutes ago")
        end
      end

      it "shows poll interval for active projects" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)
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

      it "shows restart button when workflow is not running" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :not_found, running: false)

        get project_workflow_status_path(project)
        expect(response.body).to include("Restart monitor")
      end

      it "does not show restart button when workflow is running" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)
        project.update_column(:last_polled_at, 30.seconds.ago)

        get project_workflow_status_path(project)
        expect(response.body).not_to include("Restart monitor")
      end

      it "does not show restart button when project is inactive" do
        project.update_column(:active, false)

        get project_workflow_status_path(project)
        expect(response.body).not_to include("Restart monitor")
      end
    end
  end

  describe "POST /projects/:project_id/workflow_status/restart" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post restart_project_workflow_status_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as a viewer" do
      before do
        viewer = create(:user, :viewer, account: account)
        sign_in viewer
      end

      it "redirects with authorization error" do
        allow(ProjectWorkflowManager).to receive(:restart_polling)

        post restart_project_workflow_status_path(project)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as an owner" do
      before { sign_in user }

      it "restarts the poll workflow and redirects" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :not_found, running: false)
        allow(ProjectWorkflowManager).to receive(:restart_polling)

        post restart_project_workflow_status_path(project)
        expect(ProjectWorkflowManager).to have_received(:restart_polling)
          .with(project, reason: "manual restart from UI")
        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to eq("Issue monitor restarted.")
      end

      it "redirects with alert when project is inactive" do
        project.update_column(:active, false)

        post restart_project_workflow_status_path(project)
        expect(response).to redirect_to(project_path(project))
        expect(flash[:alert]).to eq("Cannot restart monitoring on an inactive project.")
      end

      it "redirects with alert when workflow is already running" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :running, running: true)

        post restart_project_workflow_status_path(project)
        expect(response).to redirect_to(project_path(project))
        expect(flash[:alert]).to eq("Issue monitor is already running.")
      end

      it "redirects with alert when Temporal is unavailable" do
        allow(ProjectWorkflowManager).to receive(:workflow_status)
          .with(project).and_return(status: :not_found, running: false)
        allow(ProjectWorkflowManager).to receive(:restart_polling)
          .and_raise(Temporalio::Error::RPCError.new("unavailable", code: Temporalio::Error::RPCError::Code::UNAVAILABLE, raw_grpc_status: nil))

        post restart_project_workflow_status_path(project)
        expect(response).to redirect_to(project_path(project))
        expect(flash[:alert]).to eq("Could not restart issue monitor. Please try again later.")
      end

      it "does not allow restarting for other accounts' projects" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)

        post restart_project_workflow_status_path(other_project)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
