# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::MarkEscalatedActivity do
  def create_operational_failures!(issue, count: 3)
    # The operational-failure re-validation gate now keys off the persisted
    # scan-confirmation count (downtime-immune), not a wall-clock window.
    issue.update!(stuck_confirmation_count: Activities::ScanPaidPrsActivity::REQUIRED_STUCK_CONFIRMATIONS)
    count.times do |i|
      run_at = (4.hours + i.minutes + 1.minute).ago

      # Use a non-transient operational failure (Clone failed) so the breaker
      # recognizes these as escalation-worthy. "All providers exhausted" is
      # a transient outage that no longer triggers escalation.
      create(:agent_run, :failed,
        project: issue.project,
        issue: issue,
        goal: "create_pr",
        trigger_type: "automatic",
        source_pull_request_number: issue.github_number,
        error_message: "Clone failed: could not resolve host api.github.com",
        created_at: run_at,
        started_at: run_at,
        completed_at: run_at)
    end
  end

  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:add_comment)
    allow(github_client).to receive(:remove_label_from_issue)
    allow(github_client).to receive(:recent_issue_comments).and_return([])
  end

  describe "#default_reason", :no_db do
    let(:project) { double(max_draft_review_rounds: 4, max_pr_followup_runs: 3) }

    it "uses the draft-phase limit for draft PRs" do
      issue = double(draft_phase?: true)

      reason = activity.send(:default_reason, project, issue)

      expect(reason).to include("(4 consecutive unsuccessful runs)")
    end

    it "uses the ready-phase limit for non-draft PRs" do
      issue = double(draft_phase?: false)

      reason = activity.send(:default_reason, project, issue)

      expect(reason).to include("(3 consecutive unsuccessful runs)")
    end
  end

  describe "#execute" do
    context "when issue exists" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft",
          draft_review_count: 3)
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "updates pr_review_phase to escalated" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      # @spec PR-ESCALATION-002
      it "does not set the operator's auto-continue pause" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.auto_continue_paused).to be(false)
      end

      # @spec PR-ESCALATION-004
      it "leaves automatic runs already queued for the pull request in the queue" do
        queued_run = create(:agent_run,
          project: issue.project,
          issue: issue,
          source_pull_request_number: issue.github_number,
          goal: "create_pr",
          trigger_type: "automatic",
          status: "queued")

        activity.execute(issue_id: issue.id)

        expect(queued_run.reload.status).to eq("queued")
      end

      it "stores the default escalation reason as a failure streak" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_escalation_reason).to eq("failure_streak")
      end

      it "stores operational escalation reasons separately" do
        create_operational_failures!(issue)

        activity.execute(
          issue_id: issue.id,
          reason: "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"
        )

        expect(issue.reload.pr_escalation_reason).to eq("operational_failures")
      end

      it "stores review-goal retry limit escalations separately" do
        activity.execute(
          issue_id: issue.id,
          reason: "Review-goal retry budget exhausted with no meaningful progress for 3 hours (3 consecutive failures)"
        )

        expect(issue.reload.pr_escalation_reason).to eq("review_goal_retry_limit")
      end

      # @spec FOCUSED-RUN-007
      it "stores PR token-limit escalations separately" do
        activity.execute(
          issue_id: issue.id,
          reason_key: "pr_auto_continue_token_limit",
          reason: "PR auto-continue token limit reached (50000000/50000000 recorded tokens)"
        )

        expect(issue.reload.pr_escalation_reason).to eq("pr_auto_continue_token_limit")
      end

      it "persists the explicit reason key when provided" do
        create_operational_failures!(issue)

        activity.execute(
          issue_id: issue.id,
          reason_key: "operational_failures",
          reason: "anything human-facing"
        )

        expect(issue.reload.pr_escalation_reason).to eq("operational_failures")
      end

      it "persists the escalation state with a single issue update" do
        create_operational_failures!(issue)
        allow(Issue).to receive(:find_by).with(id: issue.id).and_return(issue)
        expect(issue).to receive(:update!).once.and_call_original

        activity.execute(
          issue_id: issue.id,
          reason_key: "operational_failures",
          reason: "anything human-facing"
        )
      end

      it "prefers the explicit reason key over the human-facing reason text" do
        activity.execute(
          issue_id: issue.id,
          reason_key: "review_goal_retry_limit",
          reason: "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"
        )

        expect(issue.reload.pr_escalation_reason).to eq("review_goal_retry_limit")
      end

      it "falls back to inferring from text when the reason key is unrecognized" do
        create_operational_failures!(issue)

        activity.execute(
          issue_id: issue.id,
          reason_key: "bogus_key",
          reason: "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"
        )

        expect(issue.reload.pr_escalation_reason).to eq("operational_failures")
      end

      it "adds the paid-escalated label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end

      it "keeps the local labels aligned with the escalated phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.labels).to include("paid-escalated")
      end

      it "posts an escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(issue.project.full_name, issue.github_number, a_string_including("Escalation Note"))
      end

      it "includes the unified default reason when no reason is provided" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("automatic PR failure limit"))
      end

      it "uses the draft-phase limit in the fallback reason for draft-originated escalations" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("(#{issue.project.max_draft_review_rounds} consecutive unsuccessful runs)"))
      end

      it "uses the ready-phase limit in the fallback reason outside draft" do
        issue.update!(pr_review_phase: "ready")

        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("(#{issue.project.max_pr_followup_runs} consecutive unsuccessful runs)"))
      end

      it "includes resolution instructions in the escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("**How to resolve:**"))
      end

      it "mentions the owner in the escalation comment" do
        issue.project.update!(owner_reviewer_login: "viamin")

        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("@viamin"))
      end

      it "includes the remove-label instruction" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Remove the `paid-escalated` label"))
      end

      it "adds token-cap-specific recovery guidance for PR token-limit escalations" do
        activity.execute(
          issue_id: issue.id,
          reason_key: "pr_auto_continue_token_limit",
          reason: "PR auto-continue token limit reached (50000000/50000000 recorded tokens)"
        )

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Raise `Max PR Auto-Continue Tokens`"))
        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("after raising the limit"))
        expect(github_client).not_to have_received(:add_comment)
          .with(anything, anything, a_string_including("Convert to draft"))
      end

      it "includes the hidden comment marker for future identification" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("<!-- paid:escalation-note -->"))
      end

      it "uses a custom reason when provided" do
        activity.execute(issue_id: issue.id, reason: "Draft review limit reached")

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Draft review limit reached"))
      end

      it "skips posting when an escalation comment already exists" do
        existing = OpenStruct.new(body: "<!-- paid:escalation-note -->\n**Escalation Note**")
        allow(github_client).to receive(:recent_issue_comments).and_return([ existing ])

        activity.execute(issue_id: issue.id)

        expect(github_client).not_to have_received(:add_comment)
      end

      it "returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end

      it "records an escalation decision event" do
        expect {
          activity.execute(issue_id: issue.id, reason: "Draft review limit reached")
        }.to change(OrchestrationDecision, :count).by(1)

        event = OrchestrationDecision.last
        expect(event.decision_type).to eq("escalate")
        expect(event.context["decision_status"]).to eq("applied")
        expect(event.inputs).to include("reason" => "Draft review limit reached")
      end

      it "skips a stale operational-failure escalation after the reset marker clears the live breaker" do
        issue.update!(pr_review_phase: "ready", operational_failure_reset_at: Time.current)
        create_operational_failures!(issue)

        reason = "No meaningful progress for 3 hours after 3 consecutive provider/infrastructure failures"

        result = activity.execute(issue_id: issue.id, reason: reason)

        expect(result).to eq(updated: false)
        expect(issue.reload.pr_review_phase).to eq("ready")
        expect(github_client).not_to have_received(:add_labels_to_issue)
        expect(github_client).not_to have_received(:add_comment)

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("escalate")
        expect(decision.context["decision_status"]).to eq("noop")
        expect(decision.inputs).to include("reason" => reason)
      end
    end

    context "when label addition fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still keeps the local label aligned with the escalated phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.labels).to include("paid-escalated")
      end

      it "still returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when comment posting fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
        allow(github_client).to receive(:add_comment)
          .and_raise(GithubClient::Error, "API error")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still adds the label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end

      it "still returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when issue carries the paid-ready label" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "ready",
          labels: [ "paid-generated", "paid-automation", "paid-ready" ])
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "removes the paid-ready label so the label reflects the escalated state" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(issue.project.full_name, issue.github_number, "paid-ready")
      end

      it "removes the paid-ready label locally when escalating" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.labels).to include("paid-escalated")
        expect(issue.reload.labels).not_to include("paid-ready")
      end

      it "still adds paid-escalated even if removing paid-ready fails" do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "transient")

        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end
    end

    context "when issue does not carry the paid-ready label" do
      let(:issue) do
        create(:issue, :pull_request, pr_review_phase: "draft", labels: [ "paid-automation" ])
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "does not call remove_label_from_issue for paid-ready" do
        activity.execute(issue_id: issue.id)

        expect(github_client).not_to have_received(:remove_label_from_issue)
          .with(anything, anything, "paid-ready")
      end
    end

    context "when issue is missing" do
      it "returns updated: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:updated]).to be false
      end
    end
  end
end
