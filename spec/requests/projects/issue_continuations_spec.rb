# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Issue continuations" do # @spec PARTIAL-CLOSEOUT-007 @spec PARTIAL-CLOSEOUT-008
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let(:project) do
    create(:project, account: account, github_token: github_token, created_by: user,
      owner: "acme", repo: "alpha", auto_pick_enabled: true, active: true)
  end
  let(:issue) { create(:issue, project: project, github_number: 30, paid_state: "in_progress") }
  let!(:merged_pr) do
    create(:issue, :pull_request, project: project, github_number: 31, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id, created_at: 2.days.ago)
  end

  describe "POST /projects/:project_id/agent_runs/request_continuation" do
    context "when not authenticated" do
      it "redirects to the sign in page without queueing anything" do
        post request_continuation_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "audit it" }

        expect(response).to redirect_to(new_user_session_path)
        expect(IssueContinuationRequest.count).to eq(0)
      end
    end

    context "when the user is outside the account" do
      let(:outsider) { create(:user) }

      before { sign_in outsider }

      it "does not leak cross-tenant projects" do
        post request_continuation_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "audit it" }

        expect(response).to have_http_status(:not_found)
        expect(IssueContinuationRequest.count).to eq(0)
      end
    end

    context "when authenticated without run permission" do
      let(:viewer) { create(:user, account: account) }

      before { sign_in viewer }

      it "refuses the request" do
        post request_continuation_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "audit it" }

        expect(response).not_to have_http_status(:ok)
        expect(IssueContinuationRequest.count).to eq(0)
      end
    end

    context "when authenticated as the project owner" do
      before { sign_in user }

      it "queues a scoped continuation run and records the audit event" do
        expect {
          post request_continuation_project_agent_runs_path(project),
            params: { issue_id: issue.id, reason: "The merged PR deferred the remainder." }
        }.to change(AgentRun, :count).by(1)

        request = IssueContinuationRequest.open_for_issue(issue)
        expect(request.requested_by).to eq(user)
        expect(request.reason).to eq("The merged PR deferred the remainder.")
        expect(AgentRun.last.continuation_request_id).to eq(request.id)
        expect(account.account_activity_events.where(action: "issue.continuation_requested")).to exist
        expect(response).to redirect_to(dashboard_path)
      end

      it "is idempotent across repeated submissions" do
        post request_continuation_project_agent_runs_path(project),
          params: { issue_id: issue.id, reason: "The merged PR deferred the remainder." }
        post request_continuation_project_agent_runs_path(project),
          params: { issue_id: issue.id, reason: "The merged PR deferred the remainder." }

        expect(issue.agent_runs.count).to eq(1)
        expect(IssueContinuationRequest.count).to eq(1)
      end

      it "explains the refusal for an issue without closeout evidence" do
        plain = create(:issue, project: project, github_number: 32)

        post request_continuation_project_agent_runs_path(project), params: { issue_id: plain.id, reason: "go" }

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to include("no terminal closeout evidence")
        expect(plain.agent_runs).to be_empty
      end

      it "refuses a stale click whose evidence disappeared" do
        merged_pr.update!(pr_review_phase: "draft")

        post request_continuation_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "go" }

        expect(flash[:alert]).to be_present
        expect(IssueContinuationRequest.count).to eq(0)
      end

      it "returns to the inbox when asked to" do
        post request_continuation_project_agent_runs_path(project),
          params: { issue_id: issue.id, reason: "audit", return_to: inbox_path(kind: :partial_closeout) }

        expect(response).to redirect_to(inbox_path(kind: :partial_closeout))
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/resolve_closeout" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post resolve_closeout_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "done" }

        expect(response).to redirect_to(new_user_session_path)
        expect(issue.reload.closeout_resolved_at).to be_nil
      end
    end

    context "when authenticated without run permission" do
      let(:viewer) { create(:user, account: account) }

      before { sign_in viewer }

      it "refuses the resolution" do
        post resolve_closeout_project_agent_runs_path(project), params: { issue_id: issue.id, reason: "done" }

        expect(response).not_to have_http_status(:ok)
        expect(issue.reload.closeout_resolved_at).to be_nil
      end
    end

    context "when authenticated as the project owner" do
      before { sign_in user }

      it "resolves the issue as complete against the recorded evidence" do
        post resolve_closeout_project_agent_runs_path(project),
          params: { issue_id: issue.id, reason: "Merged PR #31 covers the work." }

        issue.reload
        expect(issue.paid_state).to eq("completed")
        expect(issue.closeout_resolved_at).to be_present
        expect(issue.closeout_resolved_by).to eq(user)
        expect(account.account_activity_events.where(action: "issue.closeout_resolved")).to exist
        expect(response).to redirect_to(dashboard_path)
      end

      # @spec PARTIAL-CLOSEOUT-014 — the pane no longer submits a hidden
      # canned reason; replaying that legacy payload must be refused.
      it "refuses the legacy canned hidden reason" do
        post resolve_closeout_project_agent_runs_path(project),
          params: { issue_id: issue.id, reason: "Operator attests the recorded closeout evidence completes ##{issue.github_number}." }

        expect(flash[:alert]).to include("specific completion rationale")
        expect(issue.reload.paid_state).not_to eq("completed")
        expect(issue.closeout_resolved_at).to be_nil
      end

      it "refuses resolution without closeout evidence" do
        plain = create(:issue, project: project, github_number: 33)

        post resolve_closeout_project_agent_runs_path(project), params: { issue_id: plain.id, reason: "done" }

        expect(flash[:alert]).to include("no terminal closeout evidence")
        expect(plain.reload.paid_state).not_to eq("completed")
      end
    end
  end
end
