# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DismissEscalationActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    context "when issue is in escalated phase" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "escalated",
          pr_followup_count: 2,
          review_goal_retry_count: 3,
          auto_continue_paused: true,
          operational_failure_reset_at: 2.hours.ago,
          labels: [ "paid-generated", "paid-escalated", "paid-dismiss-escalation" ])
      end

      it "transitions pr_review_phase to ready" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "preserves the review-goal retry count" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.review_goal_retry_count).to eq(3)
      end

      it "preserves the follow-up counter and reset markers" do
        review_goal_retry_reset_at = issue.review_goal_retry_reset_at
        operational_failure_reset_at = issue.operational_failure_reset_at

        activity.execute(issue_id: issue.id)

        issue.reload
        expect(issue.pr_followup_count).to eq(2)
        expect(issue.review_goal_retry_reset_at).to eq(review_goal_retry_reset_at)
        expect(issue.operational_failure_reset_at).to eq(operational_failure_reset_at)
      end

      it "cleans up stale escalation labels locally" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.labels).not_to include("paid-escalated", "paid-dismiss-escalation")
      end

      # @spec FOCUSED-RUN-008
      it "resumes auto-continue followups" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.auto_continue_paused).to be(false)
      end

      it "does not record a token-cap override for unrelated escalations" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_auto_continue_token_limit_overridden_at).to be_nil
      end

      # @spec FOCUSED-RUN-007
      it "records a token-cap override when dismissing a token-cap escalation" do
        issue.update!(pr_escalation_reason: Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT)

        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_auto_continue_token_limit_overridden_at).to be_present
      end

      it "returns dismissed: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be true
        expect(result[:phase]).to eq("ready")
        expect(result[:current_followup_count]).to eq(2)
      end

      it "records a resume decision event" do
        expect {
          activity.execute(issue_id: issue.id)
        }.to change(OrchestrationDecision, :count).by(1)

        event = OrchestrationDecision.last
        expect(event.decision_type).to eq("resume")
        expect(event.context["decision_status"]).to eq("applied")
      end

      it "still returns dismissed: true when decision logging fails" do
        allow(OrchestrationDecision).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "boom")

        result = activity.execute(issue_id: issue.id)

        expect(result[:dismissed]).to be true
        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when the escalated PR is still draft" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "escalated",
          draft_review_count: 4,
          pr_followup_count: 2,
          review_goal_retry_count: 3,
          labels: [ "paid-generated", "paid-escalated" ])
      end

      it "resets into restarted phase with fresh draft counters" do
        result = activity.execute(issue_id: issue.id, draft: true)

        issue.reload
        expect(result[:dismissed]).to be true
        expect(result[:phase]).to eq("restarted")
        expect(issue.pr_review_phase).to eq("restarted")
        expect(issue.draft_review_count).to eq(4)
        expect(issue.pr_followup_count).to eq(2)
      end
    end

    context "when issue is not in escalated phase" do
      let(:issue) do
        create(:issue, :pull_request, pr_review_phase: "ready")
      end

      it "returns dismissed: false" do
        expect {
          result = activity.execute(issue_id: issue.id)
          expect(result[:dismissed]).to be false
        }.to change(OrchestrationDecision, :count).by(1)

        expect(OrchestrationDecision.last.context["decision_status"]).to eq("noop")
      end

      it "does not change the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when issue is missing" do
      it "returns dismissed: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:dismissed]).to be false
      end
    end
  end
end
