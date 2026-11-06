# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-045
RSpec.describe "Agent run closeout assessment recovery" do
  include_context "with stable agent run request project"

  let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix the bug") }
  let(:agent_run) do
    create(:agent_run, :paused, project: project, issue: issue, goal: "create_pr",
      branch_name: "agent/issue-42", result_commit_sha: "abc123def456")
  end

  before do
    error = Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
      category: "timeout")
    PartialCloseouts::SourceClosureRecoveryState.record_attempt(agent_run, error: error,
      branch: agent_run.branch_name, commit_sha: agent_run.result_commit_sha)
    agent_run.update!(reconciliation: agent_run.reconciliation.merge(
      "source_closure_recovery" => PartialCloseouts::SourceClosureRecoveryState.state(agent_run).merge(
        "status" => "waiting", "next_retry_at" => 1.minute.ago.iso8601
      )
    ))
  end

  describe "POST /projects/:project_id/agent_runs/:id/retry_assessment" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post retry_assessment_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "queues the recovery without creating a replacement run" do
        expect {
          post retry_assessment_project_agent_run_path(project, agent_run)
        }.not_to change(AgentRun, :count)

        expect(RecoverSourceClosureAssessmentJob).to have_been_enqueued.with(agent_run.id)
        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
      end

      it "refuses a run that is not waiting for recovery" do
        agent_run.update!(reconciliation: agent_run.reconciliation.merge(
          "source_closure_recovery" => PartialCloseouts::SourceClosureRecoveryState.state(agent_run).merge("status" => "recovered")
        ))

        post retry_assessment_project_agent_run_path(project, agent_run)

        expect(RecoverSourceClosureAssessmentJob).not_to have_been_enqueued
        expect(flash[:alert]).to include("not waiting")
      end

      it "refuses a user outside the account" do
        outsider = create(:user, account: create(:account))
        sign_in outsider

        post retry_assessment_project_agent_run_path(project, agent_run)

        expect(RecoverSourceClosureAssessmentJob).not_to have_been_enqueued
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/resume" do
    before { sign_in user }

    it "recovers the assessment instead of re-running the agent work" do
      expect {
        post resume_project_agent_run_path(project, agent_run)
      }.not_to change(AgentRun, :count)

      expect(RecoverSourceClosureAssessmentJob).to have_been_enqueued.with(agent_run.id)
      expect(agent_run.reload.status).to eq("paused")
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/retry" do
    before { sign_in user }

    it "refuses to start a replacement run while the assessment is waiting" do
      expect {
        post retry_project_agent_run_path(project, agent_run)
      }.not_to change(AgentRun, :count)

      expect(flash[:alert]).to include("closeout assessment recovery")
    end
  end

  describe "GET /projects/:project_id/agent_runs/:id" do
    before { sign_in user }

    # @spec PARTIAL-CLOSEOUT-046
    it "shows the waiting state, the diagnostics, and the recovery action" do
      get project_agent_run_path(project, agent_run)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Closeout Assessment Recovery")
      expect(response.body).to include("agent/issue-42")
      expect(response.body).to include("abc123def456")
      expect(response.body).to include("Timeout")
      expect(response.body).to include("Retry assessment")
    end
  end
end
