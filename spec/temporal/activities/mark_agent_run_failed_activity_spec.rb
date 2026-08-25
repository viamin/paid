# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunFailedActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "marks the agent run as failed with error message" do
      agent_run = create(:agent_run, :running, project: project)

      activity.execute(agent_run_id: agent_run.id, error: "Container crashed")

      agent_run.reload
      expect(agent_run.status).to eq("failed")
      expect(agent_run.error_message).to eq("Container crashed")
    end

    it "logs the failure" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, error: "Container crashed")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("Container crashed")
    end

    it "updates issue paid_state to failed when issue exists" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id, error: "Timeout")

      expect(issue.reload.paid_state).to eq("failed")
    end

    # @spec ISSUE-ENHANCEMENT-002
    it "preserves manual review after an enhancement failure" do
      issue = create(:issue, project: project, paid_state: "manual_review")
      agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "enhance_issue")

      activity.execute(agent_run_id: agent_run.id, error: "EnhanceIssueUnparseableOutput")

      expect(agent_run.reload.status).to eq("failed")
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    it "sets issue paid_state to completed for review-goal runs" do
      issue = create(:issue, :in_progress, :pull_request, project: project)
      agent_run = create(:agent_run, :running, :review_goal, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id, error: "Review failed")

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "keeps the issue in_progress for recoverable rate-limited runs" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)
      # Runner exhaustion parks the run as rate_limited with a recovery time.
      agent_run.rate_limit!(error: "All runners exhausted (will retry)", reset_at: 2.minutes.from_now)

      activity.execute(agent_run_id: agent_run.id, error: "All runners exhausted (will retry)")

      # Must NOT flip to "failed" — that arms the re-enqueue pump and mints a
      # duplicate, superseding run while this one awaits in-place retry.
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(agent_run.reload.status).to eq("rate_limited")
    end

    it "does not overwrite timeout status but updates issue state" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)
      agent_run.timeout!(error: "startup_timeout: No output received")

      activity.execute(agent_run_id: agent_run.id, error: "Activity task failed")

      agent_run.reload
      expect(agent_run.status).to eq("timeout")
      expect(agent_run.error_message).to eq("startup_timeout: No output received")
      expect(issue.reload.paid_state).to eq("failed")
    end

    # @spec FOCUSED-RUN-006
    it "increments draft_review_count for tracked failed draft followups" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 2)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2)

      activity.execute(agent_run_id: agent_run.id, error: "All runners exhausted")

      expect(issue.reload.draft_review_count).to eq(3)
    end

    # @spec FOCUSED-RUN-006
    it "increments draft_review_count for tracked timeout draft followups" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 2)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2)
      agent_run.timeout!(error: "guardrail: time_limit")

      activity.execute(agent_run_id: agent_run.id, error: "Activity task failed")

      expect(issue.reload.draft_review_count).to eq(3)
    end

    it "does not overwrite completed status or update issue" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)
      agent_run.complete!

      activity.execute(agent_run_id: agent_run.id, error: "Activity task failed")

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "does not overwrite cancelled status or update issue" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :cancelled, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id, error: "Activity task failed")

      expect(agent_run.reload.status).to eq("cancelled")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "does not overwrite cancellation that becomes visible after taking the lock" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)
      allow(agent_run).to receive(:reload) do
        agent_run.status = "cancelled"
        agent_run.completed_at = Time.current
        agent_run
      end
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      expect(agent_run).not_to receive(:fail!)

      activity.execute(agent_run_id: agent_run.id, error: "Activity task failed")

      expect(agent_run.reload.status).to eq("cancelled")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "enqueues ProcessRunQueueJob when status transitions to failed" do
      agent_run = create(:agent_run, :running, project: project)

      expect { activity.execute(agent_run_id: agent_run.id, error: "Something broke") }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "enqueues ProcessRunQueueJob even when run is already finished" do
      agent_run = create(:agent_run, :running, project: project)
      agent_run.timeout!(error: "startup_timeout: No output received")

      expect { activity.execute(agent_run_id: agent_run.id, error: "Activity task failed") }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    context "with auth failure detection" do
      it "enqueues GithubTokenValidationJob for auth-related errors" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "Authentication failed for 'https://github.com/org/repo.git'")
        }.to have_enqueued_job(GithubTokenValidationJob).with(project.github_token.id)
      end

      it "enqueues GithubTokenValidationJob for GithubClient::AuthenticationError" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "GithubClient::AuthenticationError: Invalid or expired GitHub token")
        }.to have_enqueued_job(GithubTokenValidationJob).with(project.github_token.id)
      end

      it "enqueues GithubTokenValidationJob for proxy 503 errors" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "GithubProxy responded with 503: GitHub token not available")
        }.to have_enqueued_job(GithubTokenValidationJob).with(project.github_token.id)
      end

      it "does not enqueue validation for secondary rate-limit 403s" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(
            agent_run_id: agent_run.id,
            error: "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again."
          )
        }.not_to have_enqueued_job(GithubTokenValidationJob)
      end

      it "does not enqueue validation for generic proxy 503s" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "GithubProxy responded with 503: upstream proxy overload")
        }.not_to have_enqueued_job(GithubTokenValidationJob)
      end

      it "does not enqueue validation for non-auth errors" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "Container crashed")
        }.not_to have_enqueued_job(GithubTokenValidationJob)
      end

      it "does not break the main flow when auth check raises" do
        agent_run = create(:agent_run, :running, project: project)
        allow(GithubTokens::AuthFailureChecker).to receive(:new).and_raise(StandardError, "Redis down")

        result = activity.execute(agent_run_id: agent_run.id, error: "Authentication failed")

        expect(result).to eq({ agent_run_id: agent_run.id })
        expect(agent_run.reload.status).to eq("failed")
      end

      it "handles missing github_token gracefully" do
        agent_run = create(:agent_run, :running, project: project)
        # Simulate a project whose token was deleted after the run started
        allow(project).to receive(:github_token).and_return(nil)
        allow(Project).to receive(:find).and_return(project)
        agent_run_double = agent_run
        allow(agent_run_double).to receive(:project).and_return(project)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run_double)

        expect {
          activity.execute(agent_run_id: agent_run.id, error: "Authentication failed")
        }.not_to have_enqueued_job(GithubTokenValidationJob)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, error: "error")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "sets paid_state to completed for review-goal runs" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        goal: "review", source_pull_request_number: 42)

      activity.execute(agent_run_id: agent_run.id, error: "Runner error")

      expect(agent_run.reload.status).to eq("failed")
      expect(issue.reload.paid_state).to eq("completed")
    end

    context "with a GitHub App push-permission rejection" do
      let(:client) { instance_double(GithubClient) }

      let(:rejection_error) do
        "Push failed: Command exited with code 1 — ! [remote rejected] " \
          "paid/2368-branch -> paid/2368-branch (refusing to allow a GitHub App " \
          "to create or update workflow `.github/workflows/mutation.yml` without " \
          "`workflows` permission)"
      end

      before do
        allow(GithubClient).to receive(:new).and_return(client)
        allow(client).to receive(:recent_issue_comments).and_return([])
        allow(client).to receive(:add_comment)
      end

      it "abandons the issue so it is not re-picked into an infinite loop" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        expect(agent_run.reload.status).to eq("failed")
        issue.reload
        expect(issue.paid_state).to eq("failed")
        expect(issue.runner_retry_abandoned?).to be(true)
        expect(issue.push_permission_abandoned?).to be(true)
      end

      it "excludes the issue from the auto-pick candidate source" do
        project.update!(auto_pick_enabled: true)
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        eligible = Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(project).where(id: issue.id).exists?
        expect(eligible).to be(false)
      end

      it "posts a comment explaining the actionable cause" do
        issue = create(:issue, :in_progress, project: project, github_number: 2368)
        agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        expect(client).to have_received(:add_comment) do |_repo, number, body|
          expect(number).to eq(2368)
          expect(body).to include("Push blocked: missing GitHub App permission")
          expect(body).to include("workflows")
        end
      end

      it "does not post a duplicate comment when one already exists" do
        existing = double(body: "<!-- paid: push-permission-rejection --> earlier")
        allow(client).to receive(:recent_issue_comments).and_return([ existing ])
        issue = create(:issue, :in_progress, project: project, github_number: 2368)
        agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        expect(client).not_to have_received(:add_comment)
        expect(issue.reload.push_permission_abandoned?).to be(true)
      end

      it "does not abandon review-goal runs (they don't loop)" do
        issue = create(:issue, :in_progress, :pull_request, project: project)
        agent_run = create(:agent_run, :running, :review_goal, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        expect(issue.reload.paid_state).to eq("completed")
        expect(issue.push_permission_abandoned?).to be(false)
      end

      it "still marks the run failed and keeps bookkeeping intact when comment posting fails" do
        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "API error")
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue, goal: "create_pr")

        result = activity.execute(agent_run_id: agent_run.id, error: rejection_error)

        expect(result).to eq({ agent_run_id: agent_run.id })
        expect(agent_run.reload.status).to eq("failed")
        expect(issue.reload.push_permission_abandoned?).to be(true)
      end
    end
  end
end
