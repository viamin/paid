# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AgentRuns" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "GET /projects/:project_id/agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_agent_runs_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get project_agent_runs_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Runs")
      end

      it "shows agent runs for the project" do
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get project_agent_runs_path(project)
        expect(response.body).to include("Claude Code")
      end

      it "shows empty state when no runs exist" do
        get project_agent_runs_path(project)
        expect(response.body).to include("No agent runs yet")
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        get project_agent_runs_path(other_project)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /projects/:project_id/agent_runs/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows agent run details" do
        agent_run = create(:agent_run, project: project, agent_type: "claude_code", status: "running")
        get project_agent_run_path(project, agent_run)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Run ##{agent_run.id}")
        expect(response.body).to include("Claude Code")
      end

      it "shows issue details when attached" do
        issue = create(:issue, project: project, github_number: 42, title: "Fix the bug")
        agent_run = create(:agent_run, project: project, issue: issue)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("#42")
        expect(response.body).to include("Fix the bug")
      end

      it "shows PR link when available" do
        agent_run = create(:agent_run, :completed, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Pull Request Created")
        expect(response.body).to include(agent_run.pull_request_url)
      end

      it "shows error message when run failed" do
        agent_run = create(:agent_run, :failed, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Error")
        expect(response.body).to include(agent_run.error_message)
      end

      it "shows metrics" do
        agent_run = create(:agent_run, :completed, :with_metrics, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Iterations")
        expect(response.body).to include("Duration")
        expect(response.body).to include("Tokens")
        expect(response.body).to include("Cost")
      end

      it "shows git details when available" do
        agent_run = create(:agent_run, :with_git_context, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("agent/feature-implementation")
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        other_run = create(:agent_run, project: other_project)
        get project_agent_run_path(other_project, other_run)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /projects/:project_id/agent_runs/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_project_agent_run_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the trigger form" do
        get new_project_agent_run_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Trigger Agent Run")
        expect(response.body).to include("Claude Code")
      end

      it "shows open actionable issues in dropdown" do
        create(:issue, project: project, github_number: 10, title: "Open issue", github_state: "open", paid_state: "new")
        create(:issue, project: project, github_number: 11, title: "Closed issue", github_state: "closed", paid_state: "new")
        create(:issue, project: project, github_number: 12, title: "In progress issue", github_state: "open", paid_state: "in_progress")
        get new_project_agent_run_path(project)
        expect(response.body).to include("Open issue")
        expect(response.body).not_to include("Closed issue")
        expect(response.body).not_to include("In progress issue")
      end

      it "shows message when no issues available" do
        get new_project_agent_run_path(project)
        expect(response.body).to include("No actionable open issues found")
      end

      it "includes issue URL input" do
        get new_project_agent_run_path(project)
        expect(response.body).to include("issue_url")
        expect(response.body).to include(project.full_name)
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post project_agent_runs_path(project), params: { issue_id: 1 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix the bug") }
      let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
      let(:workflow_handle) { double("WorkflowHandle", id: "manual-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles

      before do
        sign_in user
        allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
        allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)
      end

      it "starts a workflow and redirects with success message" do
        post project_agent_runs_path(project), params: { issue_id: issue.id }
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Agent run started")
      end

      it "starts workflow with correct parameters" do
        expect(temporal_client).to receive(:start_workflow).with(
          Workflows::AgentExecutionWorkflow,
          hash_including(project_id: project.id, issue_id: issue.id, agent_type: "claude_code"),
          hash_including(task_queue: "paid-tasks")
        ).and_return(workflow_handle)

        post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "claude_code" }
      end

      it "redirects with error when no issue selected" do
        post project_agent_runs_path(project)
        expect(response).to redirect_to(new_project_agent_run_path(project))
        follow_redirect!
        expect(response.body).to include("Please select an issue")
      end

      context "with issue_url parameter" do
        it "finds an existing synced issue by URL" do
          post project_agent_runs_path(project), params: {
            issue_url: "https://github.com/#{project.owner}/#{project.repo}/issues/#{issue.github_number}"
          }
          expect(response).to redirect_to(project_path(project))
        end

        it "rejects URLs from wrong repository" do
          post project_agent_runs_path(project), params: {
            issue_url: "https://github.com/other-owner/other-repo/issues/42"
          }
          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("must be from")
        end

        it "rejects invalid URLs" do
          post project_agent_runs_path(project), params: {
            issue_url: "not-a-url"
          }
          expect(response).to redirect_to(new_project_agent_run_path(project))
        end

        it "rejects URLs from non-GitHub hosts" do
          post project_agent_runs_path(project), params: {
            issue_url: "https://notgithub.com/#{project.owner}/#{project.repo}/issues/42"
          }
          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("must be from")
        end

        it "shows error when issue not synced" do
          post project_agent_runs_path(project), params: {
            issue_url: "https://github.com/#{project.owner}/#{project.repo}/issues/999"
          }
          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("not found")
        end
      end

      context "when Temporal workflow already running" do
        before do
          allow(temporal_client).to receive(:start_workflow)
            .and_raise(Temporalio::Error::WorkflowAlreadyStartedError.new(
              workflow_id: "test-workflow",
              workflow_type: "TestWorkflow",
              run_id: "test-run"
            ))
        end

        it "redirects with error message" do
          post project_agent_runs_path(project), params: { issue_id: issue.id }
          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("already in progress")
        end
      end

      context "when Temporal connection fails" do
        before do
          allow(temporal_client).to receive(:start_workflow)
            .and_raise(Temporalio::Error::RPCError.new(
              "Connection refused",
              code: Temporalio::Error::RPCError::Code::UNAVAILABLE,
              raw_grpc_status: nil
            ))
        end

        it "redirects with error message" do
          post project_agent_runs_path(project), params: { issue_id: issue.id }
          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("Failed to start agent run")
        end
      end

      it "defaults to claude_code agent type" do
        expect(temporal_client).to receive(:start_workflow).with(
          anything,
          hash_including(agent_type: "claude_code"),
          anything
        ).and_return(workflow_handle)

        post project_agent_runs_path(project), params: { issue_id: issue.id }
      end

      it "ignores invalid agent types and defaults to claude_code" do
        expect(temporal_client).to receive(:start_workflow).with(
          anything,
          hash_including(agent_type: "claude_code"),
          anything
        ).and_return(workflow_handle)

        post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "invalid" }
      end
    end
  end
end
