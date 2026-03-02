# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AgentRuns" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "GET /agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get agent_runs_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get agent_runs_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Runs")
      end

      it "shows agent runs across all projects" do
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get agent_runs_path
        expect(response.body).to include("Claude Code")
      end

      it "shows empty state when no runs exist" do
        get agent_runs_path
        expect(response.body).to include("No agent runs yet")
      end

      it "filters agent runs using Ransack q params" do
        create(:agent_run, :with_git_context, project: project, branch_name: "feature/alpha")
        create(:agent_run, :with_git_context, project: project, branch_name: "fix/beta")

        get agent_runs_path, params: { q: { branch_name_cont: "alpha" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("feature/alpha")
        expect(response.body).not_to include("fix/beta")
      end

      it "sorts agent runs ascending via Ransack sort params" do
        other_project = create(:project, account: account, github_token: github_token)
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed", created_at: 1.day.ago)

        get agent_runs_path, params: { q: { s: "created_at asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(project.name)).to be < response.body.index(other_project.name)
      end

      it "sorts agent runs descending via Ransack sort params" do
        other_project = create(:project, account: account, github_token: github_token)
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed", created_at: 1.day.ago)

        get agent_runs_path, params: { q: { s: "created_at desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(other_project.name)).to be < response.body.index(project.name)
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed")

        get agent_runs_path
        expect(response.body).not_to include(other_project.name)
      end
    end
  end

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

      it "filters agent runs using Ransack q params" do
        create(:agent_run, :with_git_context, project: project, branch_name: "feature/gamma")
        create(:agent_run, :with_git_context, project: project, branch_name: "fix/delta")

        get project_agent_runs_path(project), params: { q: { branch_name_cont: "gamma" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("feature/gamma")
        expect(response.body).not_to include("fix/delta")
      end

      it "sorts agent runs via Ransack sort params" do
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        create(:agent_run, project: project, agent_type: "cursor", status: "completed", created_at: 1.day.ago)

        get project_agent_runs_path(project), params: { q: { s: "created_at asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index("Claude Code")).to be < response.body.index("Cursor")
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

      it "includes goal-toggle Stimulus wiring" do
        get new_project_agent_run_path(project)
        body = response.body
        expect(body).to include('data-controller="goal-toggle"')
        expect(body).to include('data-action="change->goal-toggle#toggle"')
        expect(body).to include('data-goal-toggle-target="issueSection"')
        expect(body).to include('data-goal-toggle-target="prSection"')
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

      it "shows open PRs in dropdown" do
        create(:issue, :pull_request, project: project, github_number: 20, title: "Open PR")
        create(:issue, :pull_request, :closed, project: project, github_number: 21, title: "Closed PR")
        get new_project_agent_run_path(project)
        expect(response.body).to include("Open PR")
        expect(response.body).not_to include("Closed PR")
      end

      it "shows message when no PRs available" do
        get new_project_agent_run_path(project)
        expect(response.body).to include("No open pull requests found")
      end

      it "pre-selects issue when issue_id param is present" do
        issue = create(:issue, project: project, github_number: 10, title: "Preselected issue", github_state: "open", paid_state: "new")
        get new_project_agent_run_path(project, issue_id: issue.id)
        expect(response.body).to include("selected")
        expect(response.body).to include("Preselected issue")
      end

      it "pre-selects PR when pull_request_id param is present" do
        pr = create(:issue, :pull_request, project: project, github_number: 30, title: "Preselected PR")
        get new_project_agent_run_path(project, pull_request_id: pr.id)
        expect(response.body).to include("selected")
        expect(response.body).to include("Preselected PR")
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

      before do
        sign_in user
      end

      it "creates a queued run and redirects with success message" do
        post project_agent_runs_path(project), params: { issue_id: issue.id }
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Agent run")
      end

      it "creates an agent run with correct parameters" do
        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "claude_code" }
        }.to change(AgentRun, :count).by(1)

        agent_run = AgentRun.last
        expect(agent_run.project).to eq(project)
        expect(agent_run.issue).to eq(issue)
        expect(agent_run.agent_type).to eq("claude_code")
        expect(agent_run.status).to eq("queued")
      end

      it "enqueues ProcessRunQueueJob" do
        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with error when no issue selected" do
        post project_agent_runs_path(project)
        expect(response).to redirect_to(new_project_agent_run_path(project))
        follow_redirect!
        expect(response.body).to include("Please select an issue")
      end

      context "with pull_request_id parameter" do
        let(:pr) { create(:issue, :pull_request, project: project, github_number: 77, title: "Fix styles") }

        it "creates a queued run with source_pull_request_number from dropdown" do
          expect {
            post project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.to change(AgentRun, :count).by(1)

          agent_run = AgentRun.last
          expect(agent_run.source_pull_request_number).to eq(77)
          expect(agent_run.status).to eq("queued")
          expect(response).to redirect_to(project_path(project))
        end

        it "enqueues ProcessRunQueueJob for PR runs" do
          expect {
            post project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.to have_enqueued_job(ProcessRunQueueJob)
        end
      end

      context "when at capacity" do
        before do
          allow(AgentRun).to receive(:has_run_capacity?).and_return(false)
        end

        it "creates a queued agent run" do
          expect {
            post project_agent_runs_path(project), params: { issue_id: issue.id }
          }.to change(AgentRun, :count).by(1)

          expect(AgentRun.last.status).to eq("queued")
          expect(AgentRun.last.issue).to eq(issue)
        end

        it "redirects with queued notice" do
          post project_agent_runs_path(project), params: { issue_id: issue.id }

          expect(response).to redirect_to(project_path(project))
          follow_redirect!
          expect(response.body).to include("queued")
        end

        it "queues runs with custom prompt" do
          post project_agent_runs_path(project), params: {
            custom_prompt: "Fix the bug"
          }

          expect(AgentRun.last.status).to eq("queued")
          expect(AgentRun.last.custom_prompt).to eq("Fix the bug")
        end

        it "rejects duplicate queued run for the same issue via DB constraint" do
          create(:agent_run, :queued, project: project, issue: issue)

          post project_agent_runs_path(project), params: { issue_id: issue.id }

          expect(response).to redirect_to(new_project_agent_run_path(project))
          follow_redirect!
          expect(response.body).to include("already queued or in progress")
        end
      end

      it "defaults to claude_code agent type" do
        post project_agent_runs_path(project), params: { issue_id: issue.id }

        expect(AgentRun.last.agent_type).to eq("claude_code")
      end

      it "ignores invalid agent types and defaults to claude_code" do
        post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "invalid" }

        expect(AgentRun.last.agent_type).to eq("claude_code")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/retry" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :failed, project: project)
        post retry_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a new queued run from a failed run" do
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.status).to eq("queued")
        expect(new_run.project).to eq(project)
        expect(new_run.issue).to eq(agent_run.issue)
        expect(new_run.agent_type).to eq("claude_code")
        expect(response).to redirect_to(project_agent_run_path(project, new_run))
      end

      it "marks the original run as retried" do
        agent_run = create(:agent_run, :failed, project: project)

        post retry_project_agent_run_path(project, agent_run)

        expect(agent_run.reload.status).to eq("retried")
      end

      it "preserves custom_prompt from the original run" do
        agent_run = create(:agent_run, :failed, :with_custom_prompt, project: project)

        post retry_project_agent_run_path(project, agent_run)

        new_run = AgentRun.last
        expect(new_run.custom_prompt).to eq(agent_run.custom_prompt)
      end

      it "preserves source_pull_request_number from the original run" do
        agent_run = create(:agent_run, :failed, :existing_pr, project: project)

        post retry_project_agent_run_path(project, agent_run)

        new_run = AgentRun.last
        expect(new_run.source_pull_request_number).to eq(agent_run.source_pull_request_number)
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :failed, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with success notice" do
        agent_run = create(:agent_run, :failed, project: project)

        post retry_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, AgentRun.last))
        follow_redirect!
        expect(response.body).to include("retry")
      end

      it "allows retrying a timed-out run" do
        agent_run = create(:agent_run, :timeout, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        expect(AgentRun.last.status).to eq("queued")
      end

      it "allows retrying a cancelled run" do
        agent_run = create(:agent_run, :cancelled, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        expect(AgentRun.last.status).to eq("queued")
      end

      it "rejects retrying an active run" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Only finished runs can be retried")
      end

      it "does not allow retrying runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :failed, project: other_project)

        post retry_project_agent_run_path(other_project, other_run)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/refresh_auth" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        post refresh_auth_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "redirects when run is not auth_expired" do
        agent_run = create(:agent_run, :failed, project: project)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "abc123" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Only runs with expired authentication")
      end

      it "redirects when auth code is blank" do
        agent_run = create(:agent_run, :auth_expired, project: project)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "  " }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Please provide an authentication code")
      end

      it "creates a new queued run and marks original as retried on success" do
        agent_run = create(:agent_run, :auth_expired, project: project, agent_type: "claude_code")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        expect {
          post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "valid-code" }
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.status).to eq("queued")
        expect(new_run.project).to eq(project)
        expect(new_run.issue).to eq(agent_run.issue)
        expect(new_run.agent_type).to eq("claude_code")
        expect(agent_run.reload.status).to eq("retried")
        expect(response).to redirect_to(project_agent_run_path(project, new_run))
        expect(AgentHarness).to have_received(:refresh_auth).with(:claude, code: "valid-code")
      end

      it "enqueues ProcessRunQueueJob on success" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        expect {
          post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "valid-code" }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with alert when refresh_auth is not supported" do
        agent_run = create(:agent_run, :auth_expired, project: project)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "valid-code" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication is not supported")
      end

      it "redirects with alert on AgentHarness::AuthenticationError" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
            .and_raise(AgentHarness::AuthenticationError, "Invalid code")
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "bad-code" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication failed")
        expect(response.body).to include("Invalid code")
      end

      it "redirects with alert on AgentHarness::Error" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
            .and_raise(AgentHarness::Error, "Provider unavailable")
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "some-code" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication failed")
        expect(response.body).to include("Provider unavailable")
      end

      it "does not allow refreshing runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, account: other_account)
        other_project = create(:project, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :auth_expired, project: other_project)

        post refresh_auth_project_agent_run_path(other_project, other_run), params: { auth_code: "abc" }

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
